import Foundation

/// Orders native changes so an entry point is created before another is removed.
@MainActor
final class AppAccessController {
    private let settings: AppAccessSettings
    private let setMenuVisible: (Bool) -> Bool
    private let setDockVisible: (Bool) -> Bool
    private let revealWindow: () -> Void
    private let reportFailure: (String) -> Void
    private var applying = false

    init(settings: AppAccessSettings, setMenuVisible: @escaping (Bool) -> Bool,
         setDockVisible: @escaping (Bool) -> Bool, revealWindow: @escaping () -> Void,
         reportFailure: @escaping (String) -> Void) {
        self.settings = settings
        self.setMenuVisible = setMenuVisible
        self.setDockVisible = setDockVisible
        self.revealWindow = revealWindow
        self.reportFailure = reportFailure
        settings.onChange = { [weak self] in self?.apply() }
    }

    func apply() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let preferences = settings.preferences
        if preferences.showInMenuBar, !setMenuVisible(true) {
            recover(message: "The library's menu-bar icon could not appear. Dock access has been restored.")
            return
        }
        guard setDockVisible(preferences.showInDock) else {
            recover(message: "macOS could not change Dock visibility. Dock access has been restored.")
            return
        }
        if !preferences.showInMenuBar { _ = setMenuVisible(false) }
    }

    func statusItemRemoved() {
        let needsWindow = !settings.preferences.showInDock
        settings.set(.defaults)
        if needsWindow { revealWindow() }
    }

    private func recover(message: String) {
        // Keep any working menu entry if the system also refuses Dock recovery.
        if setDockVisible(true) {
            _ = setMenuVisible(false)
            settings.set(.defaults)
            reportFailure(message)
        } else {
            reportFailure("macOS could not restore Dock access. Keep the library window open and retry in Settings.")
        }
        revealWindow()
    }
}
