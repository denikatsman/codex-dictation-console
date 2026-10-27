import AppKit
import DictationArchiveCore
import ServiceManagement

/// Explicit, non-UI maintenance controls for installation and scoped checks.
/// Ordinary launch never enters this path or changes startup registration.
@MainActor
enum LifecycleControl {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--lifecycle-control") else { return false }
        guard args.indices.contains(index + 1) else { exit(2) }
        let action = args[index + 1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let manager = LoginItemManager(isQuitting: { false })
                switch action {
                case "status": break
                case "enable-login": _ = try await manager.setEnabled(true)
                case "disable-login": _ = try await manager.setEnabled(false)
                case "access-menu", "access-dock", "access-both":
                    AppAccessSettings().set(.init(showInMenuBar: action != "access-dock", showInDock: action != "access-menu"))
                case "quit-for-update":
                    let incumbents = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-dictation-console")
                        .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
                    if incumbents.isEmpty { try await manager.stopHelperForQuit() }
                    else { try await Task.detached { try ApplicationLifetime.forwardUpdateQuit() }.value }
                default: throw LabError.commandFailed("Unknown lifecycle control: \(action)")
                }
                let settings = AppAccessSettings().preferences
                let status: [String: Any] = ["login": manager.state().title,
                    "mainServiceStatus": SMAppService.mainApp.status.rawValue,
                    "legacyHelperServiceStatus": SMAppService.loginItem(identifier: LoginItemManager.helperIdentifier).status.rawValue,
                    "showInDock": settings.showInDock, "showInMenuBar": settings.showInMenuBar,
                    "helperRunning": manager.isHelperRunning,
                    "mainPIDs": NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-dictation-console")
                        .filter { $0.processIdentifier != getpid() && !$0.isTerminated }.map(\.processIdentifier)]
                let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data("\n".utf8))
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
        return true
    }
}
