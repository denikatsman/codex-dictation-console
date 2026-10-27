import AppKit
import SwiftUI

@MainActor
protocol LibraryWindow: AnyObject {
    func present()
    func recoverDisplay()
}

@MainActor
final class LibraryWindowCoordinator {
    private let makeWindow: () -> any LibraryWindow
    private var windows: [any LibraryWindow] = []
    private weak var mostRecent: (any LibraryWindow)?

    init(makeWindow: @escaping () -> any LibraryWindow) { self.makeWindow = makeWindow }

    func open() {
        if let window = mostRecent ?? windows.last { window.present() }
        else { newWindow() }
    }

    func newWindow() {
        let window = makeWindow()
        windows.append(window)
        mostRecent = window
        window.present()
    }

    func selected(_ window: any LibraryWindow) {
        guard windows.contains(where: { $0 === window }) else { return }
        mostRecent = window
    }

    func closed(_ window: any LibraryWindow) {
        windows.removeAll { $0 === window }
        if mostRecent === window { mostRecent = windows.last }
    }
    func recoverDisplays() { windows.forEach { $0.recoverDisplay() } }
}

enum LibraryWindowGeometry {
    static func recovered(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard let first = screens.first else { return frame }
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        if screens.contains(where: {
            let visible = titleBar.intersection($0)
            return visible.width >= min(160, frame.width) && visible.height >= 22
        }) { return frame }
        let target = screens.max(by: { frame.intersection($0).area < frame.intersection($1).area }) ?? first
        let width = min(frame.width, target.width), height = min(frame.height, target.height)
        return NSRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height)
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate, LibraryWindow {
    private let state: AppState
    private let selected: (any LibraryWindow) -> Void
    private let closed: (any LibraryWindow) -> Void

    init(state: AppState, restoreWindowState: Bool = true,
         selected: @escaping (any LibraryWindow) -> Void,
         closed: @escaping (any LibraryWindow) -> Void = { _ in }) {
        self.state = state
        self.selected = selected
        self.closed = closed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Codex Dictation Console"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 980, height: 650)
        window.contentView = nil
        window.delegate = self
        window.center()
        guard restoreWindowState else { return }
        let name = "CodexDictationLab.Library"
        if !window.setFrameUsingName(name) {
            // Preserve a valid frame from the former SwiftUI WindowGroup.
            let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("NSWindow Frame SwiftUI.") && $0.contains("CodexDictationLab.ContentView")
            }.sorted { $0.contains("SwiftUI.WindowGroup") && !$1.contains("SwiftUI.WindowGroup") }
            if let key = keys.first { _ = window.setFrameUsingName(String(key.dropFirst("NSWindow Frame ".count))) }
        }
        window.setFrameAutosaveName(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        guard let window else { return }
        prepareForPresentation()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        selected(self)
    }

    /// Content and geometry can be prepared without ordering a window on screen.
    func prepareForPresentation() {
        guard let window else { return }
        if window.contentView == nil {
            let host = NSHostingView(rootView: ContentView().environmentObject(state))
            host.sceneBridgingOptions = [.toolbars]
            window.contentView = host
        }
        recoverDisplay()
    }

    func recoverDisplay() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let frame = LibraryWindowGeometry.recovered(window.frame, screens: NSScreen.screens.map(\.visibleFrame))
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    func windowDidBecomeKey(_ notification: Notification) { selected(self) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state.accessSettings.preferences.showInMenuBar {
            sender.orderOut(nil)
            sender.contentView = nil
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        // A fully closed AppKit/SwiftUI window is no longer a reopen target.
        // Keep the shared AppState and create a fresh native window next time.
        closed(self)
    }
}
