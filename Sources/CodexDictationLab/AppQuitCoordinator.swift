import AppKit
import DictationArchiveCore
import Foundation

@MainActor
final class AppQuitCoordinator {
    static let shared = AppQuitCoordinator(
        confirmQuit: {
            DictationQuitConfirmation.confirm(launchAtLogin: LoginItemManager().state() == .enabled)
        },
        stopHelper: {
            try await AppServerClient.shared.cancelAllAndWait()
            try await LoginItemManager().stopHelperForQuit()
            // Also drain a fallback scan when the helper was unavailable.
            try await Task.detached { try ArchiveStore().waitForPendingWrites() }.value
        },
        reportFailure: { error in NSAlert(error: error).runModal() }
    )

    private(set) var isQuitting = false
    private var isConfirming = false
    private let confirmQuit: () -> Bool
    private let stopHelper: () async throws -> Void
    private let reportFailure: (Error) -> Void

    init(
        confirmQuit: @escaping () -> Bool,
        stopHelper: @escaping () async throws -> Void,
        reportFailure: @escaping (Error) -> Void
    ) {
        self.confirmQuit = confirmQuit
        self.stopHelper = stopHelper
        self.reportFailure = reportFailure
    }

    func requestQuit(confirm: Bool = true, reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        guard !isConfirming else { return .terminateCancel }
        isConfirming = true
        let confirmed = !confirm || confirmQuit()
        isConfirming = false
        guard confirmed else { return .terminateCancel }
        isQuitting = true
        Task {
            do {
                try await stopHelper()
                reply(true)
            } catch {
                isQuitting = false
                reply(false)
                if confirm { reportFailure(error) }
                else { fputs("Update shutdown failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        return .terminateLater
    }
}
