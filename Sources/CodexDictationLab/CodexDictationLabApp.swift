import AppKit
import DictationArchiveCore

@main
enum CodexDictationLabApp {
    @MainActor
    static func main() {
        if LifecycleControl.runIfRequested() { return }
        let background = CommandLine.arguments.contains("--background")
        let delegate = LabApplicationDelegate(backgroundLaunch: background)
        do {
            guard let ownership = try ApplicationLifetime.acquireOrForward(background: background, onOpen: { acknowledge in
                DispatchQueue.main.async { delegate.requestOpen(acknowledge: acknowledge) }
            }, onUpdateQuit: { acknowledge in
                DispatchQueue.main.async { delegate.requestUpdateQuit(acknowledge: acknowledge) }
            }) else { return }

            // Older installed versions do not hold this lock. During an upgrade,
            // leave their services alone and direct the user to that existing app.
            if let older = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-dictation-console")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.isFinishedLaunching && !$0.isTerminated }) {
                if !background {
                    older.activate(options: [.activateAllWindows])
                    fputs("An older library is still running. Quit and reopen it to load the installed update.\n", stderr)
                }
                withExtendedLifetime(ownership) {}
                return
            }
            // No model, archive writer, helper or timer exists before ownership.
            let app = NSApplication.shared
            delegate.configure(state: AppState())
            app.delegate = delegate
            app.run()
            withExtendedLifetime((ownership, delegate)) {}
        } catch {
            fputs("Codex Dictation Console: \(error.localizedDescription)\n", stderr)
            if !background {
                NSApplication.shared.setActivationPolicy(.regular)
                NSAlert(error: error).runModal()
            }
            exit(EXIT_FAILURE)
        }
    }
}
