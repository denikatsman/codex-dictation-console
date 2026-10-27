import AppKit
import Darwin
import CoreFoundation
import DictationArchiveCore
import Foundation
import ServiceManagement

enum LabError: LocalizedError {
    case missingCodexBinary
    case appServerTimeout
    case appServerStopped
    case malformedResponse
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCodexBinary:
            "The bundled Codex account service was not found."
        case .appServerTimeout:
            "The Codex account service did not respond in time."
        case .appServerStopped:
            "The Codex account service stopped before returning a snapshot."
        case .malformedResponse:
            "The Codex account response could not be read."
        case .commandFailed(let message):
            message
        }
    }
}

final class AppServerClient: @unchecked Sendable {
    static let shared = AppServerClient()
    private let lock = NSLock()
    private var sessions: [UUID: AppServerProbeSession] = [:]

    func fetchSnapshot() async throws -> AccountUsageSnapshot {
        guard let appURL = CodexApplicationLocator.locate() else { throw LabError.missingCodexBinary }
        guard let binaryURL = CodexApplicationLocator.accountServiceBinary(in: appURL) else {
            throw LabError.missingCodexBinary
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = AppServerProbeSession(binaryURL: binaryURL, onStopped: { [weak self] in
                    self?.remove(id)
                }) { result in continuation.resume(with: result) }
                lock.lock(); sessions[id] = session; lock.unlock()
                if Task.isCancelled { session.cancel() }
                else { session.start() }
            }
        } onCancel: { [weak self] in self?.session(id)?.cancel() }
    }

    private func session(_ id: UUID) -> AppServerProbeSession? {
        lock.lock(); defer { lock.unlock() }; return sessions[id]
    }
    private func remove(_ id: UUID) { lock.lock(); sessions[id] = nil; lock.unlock() }
    private func activeSessions() -> [AppServerProbeSession] {
        lock.lock(); defer { lock.unlock() }; return Array(sessions.values)
    }

    func cancelAllAndWait() async throws {
        activeSessions().forEach { $0.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !activeSessions().isEmpty {
            guard ContinuousClock.now < deadline else { throw LabError.commandFailed("The account service has not finished stopping.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

final class AppServerProbeSession: @unchecked Sendable {
    private let binaryURL: URL
    private let completion: (Result<AccountUsageSnapshot, Error>) -> Void
    private let onStopped: () -> Void
    private let queue = DispatchQueue(label: "CodexDictationLab.AppServerProbe")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private var buffer = Data()
    private var rateResult: [String: Any]?
    private var usageResult: [String: Any]?
    private var finished = false
    private var initialized = false
    private var readers: [DispatchSourceRead] = []
    private var keepAlive: AppServerProbeSession?
    private var launched = false
    private var cleaned = false
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval


    init(
        binaryURL: URL, timeout: TimeInterval = 15, terminationGrace: TimeInterval = 2,
        onStopped: @escaping () -> Void = {},
        completion: @escaping (Result<AccountUsageSnapshot, Error>) -> Void
    ) {
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.binaryURL = binaryURL
        self.completion = completion
        self.onStopped = onStopped
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func cancel() { queue.async { if !self.finished { self.finish(.failure(CancellationError())) } } }

    private func startOnQueue() {
        guard !finished else { return }
        keepAlive = self
        process.executableURL = binaryURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if !self.finished { self.finish(.failure(LabError.appServerStopped)) }
                self.cleanup()
            }
        }
        do {
            // Descriptor-local protection works for macOS pipes; leave the app's
            // signal disposition unchanged. A closed stdin becomes EPIPE.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try process.run()
            launched = true
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errorOutput.fileHandleForWriting.close()
            startReading(output.fileHandleForReading, consumeOutput: true)
            startReading(errorOutput.fileHandleForReading, consumeOutput: false)
            send([
                "method": "initialize", "id": 0,
                "params": ["clientInfo": ["name": "codex_dictation_console",
                    "title": "Codex Dictation Console", "version": "2.0.0"]]
            ])
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.finished else { return }
                self.finish(.failure(LabError.appServerTimeout))
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func startReading(_ handle: FileHandle, consumeOutput: Bool) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        reader.setEventHandler { [weak self, weak reader] in
            guard let self, let reader, !self.finished else { return }
            // Read once, using the kernel's available-byte count. All reads and
            // teardown share the state queue; no FileHandle callback races close.
            var bytes = [UInt8](repeating: 0, count: max(1, min(Int(reader.data), 65_536)))
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0, consumeOutput { self.consume(Data(bytes.prefix(count))) }
            if count == 0 { reader.cancel() }
        }
        reader.setCancelHandler { try? handle.close() }
        readers.append(reader)
        reader.resume()
    }

    private func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        readers.forEach { $0.cancel() }
        readers.removeAll()
        process.terminationHandler = nil
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForWriting, errorOutput.fileHandleForWriting] {
            try? handle.close()
        }
        if !launched {
            try? output.fileHandleForReading.close()
            try? errorOutput.fileHandleForReading.close()
        }
        keepAlive = nil
        onStopped()
    }

    private func consume(_ data: Data) {
        guard !finished, !data.isEmpty else { return }
        guard buffer.count + data.count <= 1_048_576 else {
            finish(.failure(LabError.malformedResponse)); return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let identifier = (object["id"] as? NSNumber)?.intValue
            else { continue }

            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "The Codex account request failed."
                finish(.failure(LabError.commandFailed(message)))
                return
            }
            if identifier == 0, !initialized {
                guard object["result"] is [String: Any] else {
                    finish(.failure(LabError.malformedResponse)); return
                }
                initialized = true
                send(["method": "initialized"])
                send(["method": "account/rateLimits/read", "id": 1])
                send(["method": "account/usage/read", "id": 2, "params": NSNull()])
                continue
            }
            guard initialized else { continue }
            if identifier == 1 {
                rateResult = object["result"] as? [String: Any]
            } else if identifier == 2 {
                usageResult = object["result"] as? [String: Any]
            }
            if rateResult != nil, usageResult != nil {
                do {
                    finish(.success(try makeSnapshot()))
                } catch {
                    finish(.failure(error))
                }
                return
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), !finished else { return }
        var line = data
        line.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: line)
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<AccountUsageSnapshot, Error>) {
        guard !finished else { return }
        finished = true
        readers.forEach { $0.cancel() }
        readers.removeAll()
        try? input.fileHandleForWriting.close()
        if launched, process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + terminationGrace) { [weak self] in
                guard let self, self.process.isRunning else { return }
                // Only this session's still-running child is eligible. The
                // termination callback retains cleanup responsibility until exit.
                _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
        } else {
            cleanup()
        }
        completion(result)
    }

    private func makeSnapshot() throws -> AccountUsageSnapshot {
        guard let rateResult, let usageResult else { throw LabError.malformedResponse }
        let historical = rateResult["rateLimits"] as? [String: Any]
        let dictionary = rateResult["rateLimitsByLimitId"] as? [String: Any]
        var buckets: [MeterBucketSnapshot] = []
        if let dictionary {
            for (identifier, value) in dictionary {
                guard let raw = value as? [String: Any] else { continue }
                buckets.append(Self.parseBucket(identifier: identifier, raw: raw))
            }
        } else if let historical {
            buckets.append(Self.parseBucket(
                identifier: historical["limitId"] as? String ?? "codex",
                raw: historical
            ))
        }
        buckets.sort {
            if $0.id == "codex" { return true }
            if $1.id == "codex" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let planType = historical?["planType"] as? String
            ?? (dictionary?["codex"] as? [String: Any])?["planType"] as? String
        let summary = usageResult["summary"] as? [String: Any]
        let daily = usageResult["dailyUsageBuckets"] as? [[String: Any]]
        return AccountUsageSnapshot(
            planType: planType,
            buckets: buckets,
            lifetimeTokens: Self.int64(summary?["lifetimeTokens"]),
            latestDailyTokens: daily?.last.flatMap { Self.int64($0["tokens"]) }
        )
    }

    private static func parseBucket(identifier: String, raw: [String: Any]) -> MeterBucketSnapshot {
        MeterBucketSnapshot(
            id: identifier,
            name: raw["limitName"] as? String ?? (identifier == "codex" ? "Codex" : identifier),
            primary: parseWindow(raw["primary"]),
            secondary: parseWindow(raw["secondary"])
        )
    }

    static func parseWindow(_ value: Any?) -> MeterWindowSnapshot? {
        guard let raw = value as? [String: Any] else { return nil }
        let reset = validNumber(raw["resetsAt"]).flatMap { value -> Date? in
            guard value >= 0, value <= Date.distantFuture.timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        let number = raw["usedPercent"] as? NSNumber
        let percent = number.flatMap { value -> Int? in
            let amount = value.doubleValue
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), amount.isFinite,
                  amount >= 0, amount < Double(Int.max) else { return nil }
            return Int(amount)
        }
        return MeterWindowSnapshot(
            usedPercent: percent,
            windowDurationMinutes: validNumber(raw["windowDurationMins"]).flatMap {
                $0 > 0 && $0 < Double(Int.max) && $0.rounded(.down) == $0 ? Int($0) : nil
            },
            resetsAt: reset
        )
    }

    private static func validNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemManager {
    static let helperIdentifier = "local.codex-dictation-console.capture-helper"
    static let installedPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Codex Dictation Console.app").path
    private static var pendingConfigurationCount = 0
    private static var configurationGeneration: UInt64 = 0
    private static var configurationTask: Task<LoginItemState, Error>?
    private static var operationTask: Task<LoginItemState, Error>?
    private let injectedService: (any LoginItemService)?
    private let injectedLegacyService: (any LoginItemService)?
    private let launcherOverride: (() async throws -> Void)?
    private let helperRunningOverride: (() -> Bool)?
    private let stopHelperOverride: (() async throws -> Void)?
    private let isQuitting: @MainActor () -> Bool

    init(service: (any LoginItemService)? = nil, legacyService: (any LoginItemService)? = nil,
         launchHelper: (() async throws -> Void)? = nil, helperRunning: (() -> Bool)? = nil,
         stopHelper: (() async throws -> Void)? = nil,
         isQuitting: @escaping @MainActor () -> Bool = { AppQuitCoordinator.shared.isQuitting }) {
        injectedService = service
        injectedLegacyService = legacyService
        launcherOverride = launchHelper
        helperRunningOverride = helperRunning
        stopHelperOverride = stopHelper
        self.isQuitting = isQuitting
    }

    private var service: any LoginItemService { injectedService ?? SMAppService.mainApp }
    private var legacyService: (any LoginItemService)? {
        if injectedService != nil { return injectedLegacyService }
        return SMAppService.loginItem(identifier: Self.helperIdentifier)
    }
    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/Codex Dictation Capture Helper.app")
    }

    func state() -> LoginItemState {
        guard injectedService != nil || Bundle.main.bundleURL.path == Self.installedPath else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Only an explicit user action calls this. Launch/update never registers,
    /// refreshes a fingerprint, or replays the legacy JSON preference.
    func setEnabled(_ enabled: Bool) async throws -> LoginItemState {
        guard !isQuitting() else { return state() }
        guard injectedService != nil || Bundle.main.bundleURL.path == Self.installedPath else {
            throw LabError.commandFailed("Change Open at Login from the installed Codex Dictation Console app.")
        }
        Self.pendingConfigurationCount += 1
        defer { finishOperation() }
        Self.configurationGeneration &+= 1
        let generation = Self.configurationGeneration
        let task = enqueueOperation {
            guard generation == Self.configurationGeneration, !self.isQuitting() else { return self.state() }
            if enabled {
                switch self.service.status {
                case .enabled, .requiresApproval: break
                case .notRegistered, .notFound: try self.service.register()
                @unknown default: break
                }
                // The app now owns login and its UI. Retire the old automatic
                // helper launch only after the explicit app registration succeeds.
                if self.service.status == .enabled, let legacy = self.legacyService,
                   legacy.status == .enabled || legacy.status == .requiresApproval {
                    if self.isHelperRunning {
                        try await self.stopRunningHelpers(deadline: ContinuousClock.now.advanced(by: .seconds(10)))
                    }
                    try await self.unregister(legacy)
                }
            } else {
                if self.service.status == .enabled || self.service.status == .requiresApproval {
                    try await self.unregister(self.service)
                }
                guard generation == Self.configurationGeneration, !self.isQuitting() else { return self.state() }
                if let legacy = self.legacyService, legacy.status == .enabled || legacy.status == .requiresApproval {
                    if self.isHelperRunning {
                        try await self.stopRunningHelpers(deadline: ContinuousClock.now.advanced(by: .seconds(10)))
                    }
                    try await self.unregister(legacy)
                }
            }
            return self.state()
        }
        Self.configurationTask = task
        let result = await task.result
        if generation != Self.configurationGeneration {
            if let latest = Self.configurationTask { return try await latest.value }
            return state()
        }
        Self.configurationTask = nil
        return try result.get()
    }

    private func enqueueOperation(_ operation: @escaping @MainActor () async throws -> LoginItemState) -> Task<LoginItemState, Error> {
        let previous = Self.operationTask
        let task = Task { @MainActor in
            _ = await previous?.result
            return try await operation()
        }
        Self.operationTask = task
        return task
    }

    private func finishOperation() {
        Self.pendingConfigurationCount -= 1
        if Self.pendingConfigurationCount == 0 { Self.operationTask = nil }
    }

    func launchHelper() async throws {
        guard !isQuitting() else { return }
        Self.pendingConfigurationCount += 1
        defer { finishOperation() }
        let task = enqueueOperation {
            guard !self.isQuitting(), !self.isHelperRunning else { return self.state() }
            if let launch = self.launcherOverride { try await launch(); return self.state() }
            guard FileManager.default.fileExists(atPath: self.helperURL.path) else {
                throw LabError.commandFailed("The background capture helper is missing. Reinstall Codex Dictation Console.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: self.helperURL, configuration: configuration) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if app == nil { continuation.resume(throwing: LabError.commandFailed("macOS did not start background capture.")) }
                    else { continuation.resume() }
                }
            }
            return self.state()
        }
        _ = try await task.value
    }

    var isHelperRunning: Bool {
        if let helperRunningOverride { return helperRunningOverride() }
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperIdentifier).contains { !$0.isTerminated }
    }

    func stopHelperForQuit() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while Self.pendingConfigurationCount > 0 {
            guard clock.now < deadline else { throw quitFailure() }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await stopRunningHelpers(deadline: deadline)
    }

    private func stopRunningHelpers(deadline: ContinuousClock.Instant) async throws {
        let clock = ContinuousClock()
        if let stop = stopHelperOverride { try await stop(); return }
        let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperIdentifier)
        for helper in helpers where !helper.isTerminated {
            guard helper.terminate() || helper.isTerminated else { throw quitFailure() }
        }
        while helpers.contains(where: { !$0.isTerminated }) {
            guard clock.now < deadline else { throw quitFailure() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func quitFailure() -> LabError {
        .commandFailed("Background capture could not finish stopping. The app stayed open to preserve any active archive write.")
    }

    func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func unregister(_ service: any LoginItemService) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
