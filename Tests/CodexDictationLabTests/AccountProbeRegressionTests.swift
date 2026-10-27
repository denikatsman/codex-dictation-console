import Darwin
import Foundation
import ServiceManagement
import XCTest
@testable import CodexDictationLab

final class AccountProbeRegressionTests: XCTestCase {
    func testCancellationStopsOwnedChildBeforeCleanupCompletes() async throws {
        let f = try ProbeFixture(body: "echo $$ > \"$0.pid\"\nexec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let finished = expectation(description: "cancelled request")
        let stopped = expectation(description: "owned child stopped")
        let session = AppServerProbeSession(binaryURL: f.binary, onStopped: { stopped.fulfill() }) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
            XCTAssertTrue(error is CancellationError)
            finished.fulfill()
        }
        session.start()
        let pidURL = URL(fileURLWithPath: f.binary.path + ".pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidURL.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        session.cancel()
        await fulfillment(of: [finished, stopped], timeout: 3)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCDL019020EarlyExitAndClosedStdinCompleteOnce() async throws {
        // Run with the default signal disposition in an isolated XCTest child.
        if ProcessInfo.processInfo.environment["CDL_SIGPIPE_CHILD"] != "1" {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["-XCTest", "CodexDictationLabTests.AccountProbeRegressionTests/testCDL019020EarlyExitAndClosedStdinCompleteOnce", Bundle(for: Self.self).bundleURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["CDL_SIGPIPE_CHILD"] = "1"
            let sanitizer = Bundle(for: Self.self).bundleURL.appendingPathComponent("Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib")
            if FileManager.default.fileExists(atPath: sanitizer.path) {
                // XCTest loads our bundle dynamically. A nested instrumented
                // runner must load TSan before that bundle, just like swift test.
                environment["DYLD_INSERT_LIBRARIES"] = sanitizer.path
            }
            child.environment = environment
            let output = Pipe()
            child.standardOutput = output
            child.standardError = output
            try child.run()
            let log = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .exit, String(decoding: log, as: UTF8.self))
            XCTAssertEqual(child.terminationStatus, 0, String(decoding: log, as: UTF8.self))
            XCTAssertTrue(String(decoding: log, as: UTF8.self).contains("Executed 1 test"))
            return
        }
        signal(SIGPIPE, SIG_DFL)
        for body in ["exit 0", "exec 0<&-\nsleep 0.1\nexit 0"] {
            let f = try ProbeFixture(body: body)
            defer { try? FileManager.default.removeItem(at: f.root) }
            for _ in 0..<12 {
                let result = await runProbe(f.binary)
                if case .success = result { XCTFail("Expected early-exit failure") }
            }
        }
    }

    func testCDL021FailedLaunchReleasesSessionAndDescriptors() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<12 {
            let finished = expectation(description: "failed launch")
            var session: AppServerProbeSession? = AppServerProbeSession(binaryURL: URL(fileURLWithPath: "/nonexistent/cdl-fixture")) { result in
                if case .success = result { XCTFail("Expected launch failure") }
                finished.fulfill()
            }
            weak var released = session
            session?.start()
            session = nil
            await fulfillment(of: [finished], timeout: 3)
            for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNil(released)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(after, before + 3)
    }

    func testCDL022UncooperativeChildIsReapedAfterSuccessfulRPCAndTimeout() async throws {
        for successful in [false, true] {
            let replies = successful ? """
            read first
            printf '%s\\n' '{"id":0,"result":{}}'
            read initialized
            read rates
            read usage
            printf '%s\\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":73}}}}' '{"id":2,"result":{}}'
            """ : ""
            let f = try ProbeFixture(body: "trap '' TERM\necho $$ > \"$0.pid\"\n" + replies + "\nwhile :; do sleep 0.05; done")
            defer { try? FileManager.default.removeItem(at: f.root) }
            let result = await runProbe(f.binary, timeout: 0.5)
            if successful {
                guard case .success(let snapshot) = result else { return XCTFail("Expected successful RPC: \(result)") }
                XCTAssertEqual(snapshot.buckets.first?.primary?.usedPercent, 73)
            } else if case .success = result { XCTFail("Expected timeout") }
            let pid = try XCTUnwrap(Int32(String(contentsOf: URL(fileURLWithPath: f.binary.path + ".pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            for _ in 0..<200 {
                if kill(pid, 0) == -1 && errno == ESRCH { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testCDL024UnknownUsageDoesNotBecomeZero() {
        for raw: [String: Any] in [[:], ["usedPercent": NSNull()], ["usedPercent": "bad"], ["usedPercent": true]] {
            XCTAssertNil(AppServerProbeSession.parseWindow(raw)?.usedPercent)
        }
        XCTAssertEqual(AppServerProbeSession.parseWindow(["usedPercent": 0])?.usedPercent, 0)
        XCTAssertEqual(AppServerProbeSession.parseWindow(["usedPercent": 73, "resetsAt": 100])?.usedPercent, 73)
        XCTAssertEqual(AppServerProbeSession.parseWindow(["resetsAt": 100])?.resetsAt, Date(timeIntervalSince1970: 100))
    }

    func testCDL031InitializationErrorIsReportedImmediately() async throws {
        let f = try ProbeFixture(body: "read first\nprintf '%s\\n' '{\"id\":0,\"error\":{\"message\":\"Fixture initialization rejected\"}}'\nsleep 2")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let started = Date()
        let result = await runProbe(f.binary)
        guard case .failure(let error) = result else { return XCTFail("Expected initialization failure") }
        XCTAssertEqual(error.localizedDescription, "Fixture initialization rejected")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    private func runProbe(_ binary: URL, timeout: TimeInterval = 2) async -> Result<AccountUsageSnapshot, Error> {
        await withCheckedContinuation { continuation in
            let session = AppServerProbeSession(binaryURL: binary, timeout: timeout, terminationGrace: 0.1) {
                continuation.resume(returning: $0)
            }
            session.start()
        }
    }
}

private struct ProbeFixture {
    let root: URL
    let binary: URL
    init(body: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CDL-Probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = root.appendingPathComponent("server")
        try ("#!/bin/sh\n" + body + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    }
}

@MainActor
final class LoginItemRegressionTests: XCTestCase {
    func testCDL016LatestDisableWinsWhileEnableIsAwaitingUnregister() async throws {
        let main = FakeLoginService(status: .enabled)
        let legacy = FakeLoginService(status: .enabled)
        let manager = LoginItemManager(service: main, legacyService: legacy)
        let enable = Task { try await manager.setEnabled(true) }
        try await waitForUnregister(legacy)
        let disable = Task { try await manager.setEnabled(false) }
        try await Task.sleep(for: .milliseconds(20))
        legacy.finishUnregister()
        try await waitForUnregister(main)
        main.finishUnregister()
        _ = try await enable.value
        _ = try await disable.value
        XCTAssertEqual(main.registerCalls, 0)
        XCTAssertEqual(main.status, .notRegistered)
    }

    func testCDL016LatestEnableWinsWhileDisableIsAwaitingUnregister() async throws {
        let service = FakeLoginService(status: .enabled)
        let manager = LoginItemManager(service: service)
        let disable = Task { try await manager.setEnabled(false) }
        try await waitForUnregister(service)
        let enable = Task { try await manager.setEnabled(true) }
        try await Task.sleep(for: .milliseconds(20))
        service.finishUnregister()
        _ = try await disable.value
        _ = try await enable.value
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.status, .enabled)
    }

    private func waitForUnregister(_ service: FakeLoginService) async throws {
        for _ in 0..<200 {
            if service.pending != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Unregister was not reached")
    }
}

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status
    var registerCalls = 0
    var pending: (@Sendable (Error?) -> Void)?
    init(status: SMAppService.Status) { self.status = status }
    func register() throws { registerCalls += 1; status = .enabled }
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) { pending = completionHandler }
    func finishUnregister() {
        status = .notRegistered
        let callback = pending
        pending = nil
        callback?(nil)
    }
}
