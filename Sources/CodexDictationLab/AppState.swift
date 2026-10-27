import AppKit
import Darwin
import DictationArchiveCore
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let openDictationLogNotification = Notification.Name("local.codex-dictation-console.open-log")
    @Published var section: AppSection = .overview
    @Published var selectedRecordID: String?
    @Published private(set) var records: [ArchivedDictationRecord] = []
    @Published private(set) var recordsRevision: UInt64 = 0
    @Published private(set) var deletedRecords: [ArchivedDictationRecord] = []
    @Published private(set) var statistics: ArchiveStatistics = .empty
    @Published private(set) var captureHealth: CaptureHealthSnapshot?
    @Published private(set) var captureSettings: CaptureSettings = .default
    @Published private(set) var loginItemState: LoginItemState = .unavailable
    @Published private(set) var helperIsRunning = false
    @Published private(set) var helperLaunchError: String?
    @Published private(set) var buildEvidence: ChatGPTBuildEvidence?
    @Published private(set) var archiveIntegrity = "Not checked"
    @Published private(set) var archiveVerification: ArchiveVerificationSummary?
    @Published private(set) var archiveVerificationError: String?
    @Published private(set) var archiveLoadError: String?
    @Published private(set) var hasLoadedArchive = false
    @Published private(set) var usage: AccountUsageSnapshot?
    @Published private(set) var usageError: String?
    @Published private(set) var isLoadingArchive = false
    @Published private(set) var isVerifyingArchive = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSavingSettings = false
    @Published private(set) var isRefreshingUsage = false
    @Published var alertMessage: String?

    let layout: ArchiveLayout
    let accessSettings: AppAccessSettings
    private let sourceURL: URL
    private let afterSnapshot: @Sendable () async -> Void
    private let beforeVerification: @Sendable () async -> Void
    private let playbackAssets: NativePlaybackAssetStore
    private lazy var store = ArchiveStore(layout: layout)
    lazy var transcriptRecovery = TranscriptRecoveryModel(store: store)
    private lazy var exporter = ArchiveExporter(store: store)
    private lazy var captureEngine = DictationCaptureEngine(
        sourceURL: sourceURL,
        layout: layout,
        processKind: .mainApp
    )
    private lazy var settingsStore = CaptureSettingsStore(layout: layout)
    private lazy var statusStore = CaptureStatusStore(layout: layout)
    private let appServerClient = AppServerClient.shared
    private let loginItemManager: LoginItemManager
    private var lastBuildStamp: CodexBuildStamp?
    private var didBootstrap = false
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh: RefreshRequest?
    private var mutationRevision: UInt64 = 0
    private var lastArchiveStamp: ArchiveChangeStamp?
    private var didAttemptArchiveVerification = false
    private let activityCache = DailyActivityCache()
    private let now: () -> Date
    private let currentCalendar: () -> Calendar

    init(layout: ArchiveLayout = ArchiveLayout(), sourceURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/dictation-history"), playbackAssets: NativePlaybackAssetStore = .shared, afterSnapshot: @escaping @Sendable () async -> Void = {}, beforeVerification: @escaping @Sendable () async -> Void = {}, accessSettings: AppAccessSettings? = nil,
         now: @escaping () -> Date = Date.init, currentCalendar: @escaping () -> Calendar = { .autoupdatingCurrent },
         loginItemManager: LoginItemManager? = nil) {
        self.layout = layout
        self.accessSettings = accessSettings ?? AppAccessSettings()
        self.sourceURL = sourceURL
        self.playbackAssets = playbackAssets
        self.afterSnapshot = afterSnapshot
        self.beforeVerification = beforeVerification
        self.now = now
        self.currentCalendar = currentCalendar
        self.loginItemManager = loginItemManager ?? LoginItemManager()
    }
    private lazy var captureSupervisor = BackgroundCaptureSupervisor(
        isQuitting: { AppQuitCoordinator.shared.isQuitting },
        captureEnabled: { [weak self] in self?.settingsStore.load().captureEnabled == true },
        helperRunning: { [weak self] in self?.loginItemManager.isHelperRunning == true },
        scanIsRecent: { [weak self] in self?.statusStore.load()?.isRecentAndHealthy() == true },
        launchHelper: { [weak self] in try await self?.loginItemManager.launchHelper() },
        refresh: { [weak self] scanSource in await self?.refreshArchive(scanSource: scanSource, showErrors: false) },
        reportLaunchError: { [weak self] error in self?.assign(\.helperLaunchError, error) }
    )

    var installedCodexPath: String? { lastBuildStamp?.appPath }

    var captureNeedsAttention: Bool {
        captureSettings.captureEnabled && !captureSettings.isPaused
            && (helperLaunchError != nil || captureHealth.map { !$0.isRecentAndHealthy() } == true
                || (hasLoadedArchive && captureHealth == nil))
    }

    func showRecording(id: String) {
        selectedRecordID = id
        section = .history
    }

    func openDictationLog() {
        NotificationCenter.default.post(name: Self.openDictationLogNotification, object: self)
    }

    var dailyActivity: [DailyArchiveActivity] {
        activityCache.value(records: records, revision: recordsRevision, now: now(), calendar: currentCalendar())
    }

    var dailyActivityComputationCount: Int { activityCache.computationCount }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        async let archive: Void = refreshArchive(scanSource: true)
        do {
            assign(\.captureSettings, try settingsStore.loadChecked())
            assign(\.loginItemState, loginItemManager.state())
            if captureSettings.captureEnabled { await startHelper() }
        } catch {
            assign(\.captureSettings, .unavailable)
            alertMessage = error.localizedDescription
        }
        captureSupervisor.start()
        await archive
        await refreshUsage()
    }

    func refreshAll() async {
        async let archive: Void = refreshArchive(scanSource: true, verifyFiles: true)
        async let account: Void = refreshUsage()
        _ = await (archive, account)
    }

    func refreshArchive(scanSource: Bool = false, verifyFiles: Bool = false, showErrors: Bool = true) async {
        guard !AppQuitCoordinator.shared.isQuitting else { return }
        // Health stays visible even while a slow verification or a blocked
        // writer keeps the archive task busy.
        refreshCaptureStatus()
        let request = RefreshRequest(scan: scanSource, verify: verifyFiles, showErrors: showErrors)
        pendingRefresh = pendingRefresh.map { $0.merging(request) } ?? request
        if let refreshTask { await refreshTask.value; return }
        let task = Task {
            while let request = pendingRefresh {
                guard !AppQuitCoordinator.shared.isQuitting else { pendingRefresh = nil; break }
                pendingRefresh = nil
                await performRefresh(request)
            }
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(_ request: RefreshRequest) async {
        let scanSource = request.scan
        let verifyFiles = request.verify
        let showErrors = request.showErrors
        let revision = mutationRevision
        assign(\.isLoadingArchive, scanSource || verifyFiles || !hasLoadedArchive)
        defer { assign(\.isLoadingArchive, false) }
        let store = self.store
        let engine = captureEngine
        let statusStore = self.statusStore
        let priorBuildEvidence = buildEvidence
        let inspector = InstalledChatGPTInspector()
        let buildStamp = inspector.buildStamp
        let shouldInspectBuild = verifyFiles || priorBuildEvidence == nil || buildStamp != lastBuildStamp
        let shouldVerifyFiles = verifyFiles || !didAttemptArchiveVerification
        let priorRecords = records
        let priorDeletedRecords = deletedRecords
        let priorStatistics = statistics
        let priorIntegrity = archiveIntegrity
        let priorStamp = lastArchiveStamp
        let priorLoaded = hasLoadedArchive
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    var scanError: String?
                    if scanSource {
                        do { _ = try engine.scan() }
                        catch { scanError = error.localizedDescription }
                    }
                    let stamp = try ArchiveChangeStamp(databaseURL: store.layout.databaseURL)
                    if priorLoaded, !shouldVerifyFiles, stamp == priorStamp {
                        return ArchiveRefreshResult(snapshot: nil, stamp: stamp, scanError: scanError)
                    }
                    let currentRecords = try store.records()
                    let currentDeletedRecords = try store.records(deleted: true)
                    let archiveChanged = currentRecords != priorRecords
                        || currentDeletedRecords != priorDeletedRecords
                    let snapshot = try LocalArchiveSnapshot(
                        records: currentRecords,
                        deletedRecords: currentDeletedRecords,
                        statistics: shouldVerifyFiles || archiveChanged
                            ? store.statistics(for: currentRecords)
                            : priorStatistics,
                        captureHealth: statusStore.load(),
                        archiveIntegrity: shouldVerifyFiles || archiveChanged ? store.quickCheck() : priorIntegrity,
                        scanError: scanError
                    )
                    return ArchiveRefreshResult(snapshot: snapshot, stamp: stamp, scanError: scanError)
                }
            }.value
            if snapshot.snapshot != nil { await afterSnapshot() }
            guard revision == mutationRevision else {
                pendingRefresh = pendingRefresh.map { $0.merging(request) } ?? request
                return
            }
            if let loaded = snapshot.snapshot {
                if records != loaded.records { records = loaded.records; recordsRevision &+= 1 }
                if deletedRecords != loaded.deletedRecords { deletedRecords = loaded.deletedRecords }
                assign(\.statistics, loaded.statistics)
                assign(\.captureHealth, loaded.captureHealth)
                assign(\.archiveIntegrity, loaded.archiveIntegrity)
            }
            lastArchiveStamp = snapshot.stamp
            assign(\.archiveLoadError, nil)
            assign(\.hasLoadedArchive, true)
            refreshCaptureStatus()
            if showErrors, let scanError = snapshot.scanError { alertMessage = scanError }
        } catch {
            assign(\.archiveLoadError, error.localizedDescription)
            assign(\.archiveIntegrity, "Unavailable: \(error.localizedDescription)")
            refreshCaptureStatus()
            if showErrors { alertMessage = error.localizedDescription }
            return
        }

        // Make saved transcripts usable before hashing the installed Codex app
        // and every archived recording. Failure here must not hide the library
        // or overwrite a successful database check.
        assign(\.isLoadingArchive, false)
        assign(\.isVerifyingArchive, shouldVerifyFiles)
        defer { assign(\.isVerifyingArchive, false) }
        if shouldInspectBuild {
            buildEvidence = await Task.detached(priority: .utility) { inspector.inspect() }.value
            lastBuildStamp = buildStamp
        }
        if shouldVerifyFiles {
            didAttemptArchiveVerification = true
            await beforeVerification()
            do {
                let verification = try await Task.detached(priority: .utility) {
                    try store.verifyArchivedFiles()
                }.value
                guard revision == mutationRevision else {
                    pendingRefresh = pendingRefresh.map { $0.merging(request) } ?? request
                    return
                }
                assign(\.archiveVerification, verification)
                assign(\.archiveVerificationError, nil)
            } catch {
                assign(\.archiveVerificationError, error.localizedDescription)
                if showErrors { alertMessage = "Archive verification could not finish. \(error.localizedDescription)" }
            }
        }
    }

    func refreshSystemState() {
        accessSettings.reload()
        refreshCaptureStatus()
    }

    func reconcileAfterWake() async {
        refreshSystemState()
        await captureSupervisor.check()
    }

    private func refreshCaptureStatus() {
        if activityCache.invalidateCalendarIfChanged(now: now(), calendar: currentCalendar()) {
            objectWillChange.send()
        }
        assign(\.captureHealth, statusStore.load())
        assign(\.captureSettings, settingsStore.load())
        assign(\.loginItemState, loginItemManager.state())
        assign(\.helperIsRunning, loginItemManager.isHelperRunning)
    }

    func refreshUsage() async {
        guard !AppQuitCoordinator.shared.isQuitting, !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        do {
            usage = try await appServerClient.fetchSnapshot()
            usageError = nil
        } catch {
            usageError = error.localizedDescription
        }
    }

    func searchArchive(_ query: String) async -> [ArchivedDictationRecord] {
        let store = self.store
        do {
            return try await Task.detached(priority: .userInitiated) {
                try store.records(search: query)
            }.value
        } catch {
            if !Task.isCancelled {
                alertMessage = "The archive search failed. \(error.localizedDescription)"
            }
            return []
        }
    }

    func setCaptureEnabled(_ enabled: Bool) async {
        guard await saveSettings({ $0.captureEnabled = enabled; if enabled { $0.isPaused = false } }) else { return }
        if enabled {
            await startHelper()
            await refreshArchive(scanSource: true)
        } else {
            await refreshArchive()
        }
    }

    func setPaused(_ paused: Bool) async {
        guard await saveSettings({ $0.isPaused = paused }) else { return }
        if !paused, captureSettings.captureEnabled {
            await startHelper()
            await refreshArchive(scanSource: true)
        } else {
            await refreshArchive()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            loginItemState = try await loginItemManager.setEnabled(enabled)
        } catch {
            loginItemState = .failed(error.localizedDescription)
            alertMessage = "The login helper could not be updated. \(error.localizedDescription)"
        }
        if captureSettings.captureEnabled { await startHelper() }
        helperIsRunning = loginItemManager.isHelperRunning
    }

    func moveToRecentlyDeleted(id: String) async {
        mutationRevision &+= 1
        let store = self.store
        do {
            try await Task.detached(priority: .utility) { try store.softDelete(id: id) }.value
            mutationRevision &+= 1
            await refreshArchive()
        } catch {
            alertMessage = "The recording could not be moved to Recently Deleted. \(error.localizedDescription)"
        }
    }

    func restore(id: String) async {
        mutationRevision &+= 1
        let store = self.store
        do {
            try await Task.detached(priority: .utility) { try store.restore(id: id) }.value
            mutationRevision &+= 1
            await refreshArchive()
        } catch {
            alertMessage = "The recording could not be restored. \(error.localizedDescription)"
        }
    }

    func permanentlyDelete(id: String) async {
        mutationRevision &+= 1
        let store = self.store
        do {
            // Keep the row available for retry if derived-file cleanup fails.
            // The durable archive deletion starts only after this succeeds.
            try await playbackAssets.removeCachedPlaybackFiles(recordID: id)
            try await Task.detached(priority: .utility) {
                try store.permanentlyDelete(id: id)
            }.value
            mutationRevision &+= 1
            await refreshArchive()
        } catch {
            await refreshArchive()
            alertMessage = "Permanent deletion is incomplete. Retry deletion to finish cleanup. \(error.localizedDescription)"
        }
    }

    func export(recordID: String, to directory: URL) async -> URL? {
        guard !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        let exporter = self.exporter
        do {
            return try await Task.detached(priority: .utility) {
                try exporter.export(recordID: recordID, to: directory)
            }.value
        } catch {
            alertMessage = "The recording could not be exported. \(error.localizedDescription)"
            return nil
        }
    }

    func exportAll(to directory: URL) async -> URL? {
        guard !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        let exporter = self.exporter
        do {
            return try await Task.detached(priority: .utility) {
                try exporter.exportAll(to: directory)
            }.value
        } catch {
            alertMessage = "The archive could not be exported. \(error.localizedDescription)"
            return nil
        }
    }

    func revealArchive() {
        do {
            try layout.prepare()
            NSWorkspace.shared.activateFileViewerSelecting([layout.archiveURL])
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func revealSourceHistory() {
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/dictation-history", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }

    func openChatGPTSettings() {
        if let settingsURL = URL(string: "codex://settings"), NSWorkspace.shared.open(settingsURL) {
            return
        }
        guard let appURL = CodexApplicationLocator.locate() else {
            alertMessage = "The Codex desktop app could not be located."
            return
        }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func openLoginItemSettings() {
        loginItemManager.openLoginItemSettings()
    }

    private func saveSettings(_ change: @escaping @Sendable (inout CaptureSettings) -> Void) async -> Bool {
        guard !isSavingSettings else { return false }
        isSavingSettings = true
        defer { isSavingSettings = false }
        let settingsStore = self.settingsStore
        do {
            // A scan or export may hold the archive lock. Waiting for it on
            // the main actor would freeze every window and the Quit controls.
            captureSettings = try await Task.detached(priority: .userInitiated) {
                try settingsStore.update(change)
            }.value
            return true
        } catch {
            alertMessage = "The capture settings could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    private func startHelper() async {
        do {
            try await loginItemManager.launchHelper()
            assign(\.helperLaunchError, nil)
        } catch {
            assign(\.helperLaunchError, error.localizedDescription)
        }
    }
}

private struct LocalArchiveSnapshot: Sendable {
    let records: [ArchivedDictationRecord]
    let deletedRecords: [ArchivedDictationRecord]
    let statistics: ArchiveStatistics
    let captureHealth: CaptureHealthSnapshot?
    let archiveIntegrity: String
    let scanError: String?
}

private struct ArchiveRefreshResult: Sendable {
    let snapshot: LocalArchiveSnapshot?
    let stamp: ArchiveChangeStamp
    let scanError: String?
}

private struct RefreshRequest {
    var scan: Bool
    var verify: Bool
    var showErrors: Bool
    func merging(_ other: Self) -> Self {
        Self(scan: scan || other.scan, verify: verify || other.verify, showErrors: showErrors || other.showErrors)
    }
}
