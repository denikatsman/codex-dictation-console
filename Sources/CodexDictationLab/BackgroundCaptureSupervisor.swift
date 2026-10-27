import Foundation

/// Owned by the app, rather than a window, so closing the library does not
/// remove the fallback if the independent capture worker stops responding.
@MainActor
final class BackgroundCaptureSupervisor {
    private let isQuitting: () -> Bool
    private let captureEnabled: () -> Bool
    private let helperRunning: () -> Bool
    private let scanIsRecent: () -> Bool
    private let launchHelper: () async throws -> Void
    private let refresh: (Bool) async -> Void
    private let reportLaunchError: (String?) -> Void
    private var task: Task<Void, Never>?
    private var isChecking = false
    private var failedLaunches = 0
    private var nextLaunchAttempt = Date.distantPast
    private let now: () -> Date

    init(
        isQuitting: @escaping () -> Bool,
        captureEnabled: @escaping () -> Bool,
        helperRunning: @escaping () -> Bool,
        scanIsRecent: @escaping () -> Bool,
        launchHelper: @escaping () async throws -> Void,
        refresh: @escaping (Bool) async -> Void,
        reportLaunchError: @escaping (String?) -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.isQuitting = isQuitting
        self.captureEnabled = captureEnabled
        self.helperRunning = helperRunning
        self.scanIsRecent = scanIsRecent
        self.launchHelper = launchHelper
        self.refresh = refresh
        self.reportLaunchError = reportLaunchError
        self.now = now
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                do { try await Task.sleep(for: .seconds(10), tolerance: .seconds(2)) }
                catch { return }
            }
        }
    }

    func check() async {
        guard !isQuitting(), !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if helperRunning() { failedLaunches = 0; nextLaunchAttempt = .distantPast }
        if captureEnabled(), !helperRunning(), now() >= nextLaunchAttempt {
            do {
                try await launchHelper()
                reportLaunchError(nil)
                failedLaunches = 0
                nextLaunchAttempt = .distantPast
            } catch {
                reportLaunchError(error.localizedDescription)
                failedLaunches = min(failedLaunches + 1, 6)
                nextLaunchAttempt = now().addingTimeInterval(min(300, 10 * pow(2, Double(failedLaunches - 1))))
            }
        }
        guard !isQuitting() else { return }
        // A process can exist without doing useful work. A stale or failed
        // heartbeat deserves a fallback scan too; never force-kill a writer.
        await refresh(captureEnabled() && (!helperRunning() || !scanIsRecent()))
    }
}
