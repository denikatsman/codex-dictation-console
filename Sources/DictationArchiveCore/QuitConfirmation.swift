import AppKit

public enum DictationQuitConfirmation {
    @MainActor
    public static func confirm(launchAtLogin: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit Codex Dictation Console?"
        let resume = launchAtLogin
            ? "You can reopen the app at any time. It will also run in the background at your next login."
            : "You can reopen the app at any time."
        alert.informativeText = "Quitting stops saving new dictations in the background. Your saved text and audio stay safe.\n\n\(resume)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
