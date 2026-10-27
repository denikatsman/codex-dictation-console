import AppKit
import SwiftUI

@MainActor
protocol LibraryApplicationLifecycle: AnyObject {
    func start()
    func openMain()
    func refreshSystemState()
}

extension LibraryApplicationLifecycle { func refreshSystemState() {} }

@MainActor
final class LabApplicationDelegate: NSObject, NSApplicationDelegate {
    private let backgroundLaunch: Bool
    private var lifecycle: (any LibraryApplicationLifecycle)?
    private var didFinishLaunching = false
    private var pendingOpen = false
    private var acknowledgements: [@Sendable () -> Void] = []
    private var updateQuitAcknowledgement: (@Sendable () -> Void)?
    private var updateQuitReady = false
    private let quitCoordinator: AppQuitCoordinator

    init(backgroundLaunch: Bool = false, lifecycle: (any LibraryApplicationLifecycle)? = nil,
         quitCoordinator: AppQuitCoordinator? = nil) {
        self.backgroundLaunch = backgroundLaunch
        self.lifecycle = lifecycle
        self.quitCoordinator = quitCoordinator ?? .shared
        super.init()
    }

    func configure(state: AppState) { lifecycle = LibraryApplicationController(state: state) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        lifecycle?.start()
        if pendingOpen || (!backgroundLaunch && !Self.isBackgroundEvent(NSAppleEventManager.shared().currentAppleEvent)) {
            lifecycle?.openMain()
        }
        pendingOpen = false
        let replies = acknowledgements
        acknowledgements.removeAll()
        replies.forEach { $0() }
    }

    static func isBackgroundEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        let launchKind = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return launchKind == keyAELaunchedAsLogInItem || launchKind == keyAELaunchedAsServiceItem
            || event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
            || event?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem)?.booleanValue == true
    }

    func requestOpen(acknowledge: (@Sendable () -> Void)? = nil) {
        if didFinishLaunching {
            lifecycle?.openMain()
            acknowledge?()
        } else {
            pendingOpen = true
            if let acknowledge { acknowledgements.append(acknowledge) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !Self.isBackgroundEvent(NSAppleEventManager.shared().currentAppleEvent) else { return false }
        requestOpen()
        return false // The coordinator handled both closed and minimized windows.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) { lifecycle?.refreshSystemState() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updateQuitReady { return .terminateNow }
        return quitCoordinator.requestQuit { sender.reply(toApplicationShouldTerminate: $0) }
    }

    func requestUpdateQuit(acknowledge: @escaping @Sendable () -> Void) {
        guard updateQuitAcknowledgement == nil else { return }
        updateQuitAcknowledgement = acknowledge
        // Drain before entering AppKit termination. terminateLater from inside
        // a main-dispatch callback can prevent its own async reply from running.
        _ = quitCoordinator.requestQuit(confirm: false) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                self.updateQuitReady = true
                self.updateQuitAcknowledgement?()
                NSApp.terminate(nil)
            }
            self.updateQuitAcknowledgement = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class LibraryApplicationController: NSObject, LibraryApplicationLifecycle {
    let state: AppState
    private var started = false
    private var bootstrapTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private let popover = NSPopover()
    private var dictationLog: RecentDictationsWindowController?
    private lazy var windows: LibraryWindowCoordinator = LibraryWindowCoordinator { [unowned self] in
        LibraryWindowController(state: state,
            selected: { [weak self] in self?.windows.selected($0) },
            closed: { [weak self] in self?.windows.closed($0) })
    }
    private lazy var access = AppAccessController(
        settings: state.accessSettings,
        setMenuVisible: { [weak self] in self?.setMenuVisible($0) ?? false },
        setDockVisible: { visible in
            let desiredPolicy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
            // A launch can already have the requested policy. A no-op setter
            // returning false must not trigger a recovery alert or reset access.
            if NSApp.activationPolicy() == desiredPolicy { return true }
            let wasActive = NSApp.isActive
            let keyWindow = NSApp.keyWindow
            let succeeded = NSApp.setActivationPolicy(desiredPolicy) || NSApp.activationPolicy() == desiredPolicy
            if succeeded && wasActive {
                NSApp.activate(ignoringOtherApps: true)
                keyWindow?.makeKeyAndOrderFront(nil)
            }
            return succeeded
        },
        revealWindow: { [weak self] in self?.openMain() },
        reportFailure: { [weak self] in self?.state.alertMessage = $0 }
    )

    init(state: AppState) { self.state = state; super.init() }

    func start() {
        guard !started else { return }
        started = true
        installMenus()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: DictationStatusCard(
            state: state,
            open: { [weak self] in self?.openMain() },
            settings: { [weak self] in self?.openSettings() },
            latest: { [weak self] id in self?.state.showRecording(id: id); self?.openMain() },
            dismiss: { [weak self] in self?.popover.performClose(nil) }
        ))
        access.apply()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(showDictationLog(_:)),
            name: AppState.openDictationLogNotification, object: state)
        bootstrapTask = Task { [state] in await state.bootstrap() }
    }

    func openMain() {
        popover.performClose(nil)
        windows.open()
    }

    func refreshSystemState() { state.refreshSystemState() }
    @objc nonisolated private func calendarChanged() {
        Task { @MainActor [weak self] in self?.state.refreshSystemState() }
    }
    @objc private func systemDidWake() { Task { [state] in await state.reconcileAfterWake() } }

    @objc private func openFromMenu(_ sender: Any?) { openMain() }
    @objc private func openSettings() { state.section = .settings; openMain() }
    @objc private func newWindow() { popover.performClose(nil); windows.newWindow() }
    @objc private func refresh() { Task { [state] in await state.refreshAll() } }
    @objc private func displaysChanged() { windows.recoverDisplays(); dictationLog?.recoverDisplay() }
    @objc private func showDictationLog(_ sender: Any?) {
        popover.performClose(nil)
        if dictationLog == nil {
            dictationLog = RecentDictationsWindowController(state: state) { [weak self] id in
                self?.state.showRecording(id: id)
                self?.openMain()
            }
        }
        dictationLog?.present()
    }

    private func setMenuVisible(_ visible: Bool) -> Bool {
        if !visible {
            popover.performClose(nil)
            visibilityObservation?.invalidate()
            visibilityObservation = nil
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return true
        }
        if let statusItem { return statusItem.isVisible }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { NSStatusBar.system.removeStatusItem(item); return false }
        let image = NSImage(systemSymbolName: "mic.square", accessibilityDescription: "Codex Dictation Console")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Codex Dictation Console"
        button.setAccessibilityLabel("Codex Dictation Console")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.behavior = .removalAllowed
        statusItem = item
        let identity = ObjectIdentifier(item)
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor [weak self] in
                guard let self, let current = self.statusItem, ObjectIdentifier(current) == identity else { return }
                self.access.statusItemRemoved()
            }
        }
        return item.isVisible
    }

    @objc private func statusItemClicked() {
        guard let item = statusItem, let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.addItem(command("Open Codex Dictation Console", #selector(openFromMenu(_:))))
            menu.addItem(command("Floating Dictation Log", #selector(showDictationLog(_:))))
            menu.addItem(command("Settings…", #selector(openSettings)))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit Codex Dictation Console", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
            if let event = NSApp.currentEvent { NSMenu.popUpContextMenu(menu, with: event, for: button) }
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func command(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func installMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("Codex Dictation Console")
        app.addItem(NSMenuItem(title: "About Codex Dictation Console", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(command("Settings…", #selector(openSettings), key: ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Codex Dictation Console", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Codex Dictation Console", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let file = submenu("File")
        file.addItem(command("New Window", #selector(newWindow), key: "n"))
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                    ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                    ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        let view = submenu("View")
        view.addItem(NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: ""))
        view.addItem(command("Refresh", #selector(refresh), key: "r"))
        let window = submenu("Window")
        let log = command("Latest Dictations", #selector(showDictationLog(_:)), key: "l")
        log.keyEquivalentModifierMask = [.command, .shift]
        window.addItem(log)
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
