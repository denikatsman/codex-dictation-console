import AppKit
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

@MainActor
final class AppAccessTests: XCTestCase {
    func testExternalModeChangesReloadAndInvalidBothOffRepairsPersistence() {
        let (settings, defaults) = settings()
        defaults.set(["showInMenuBar": true, "showInDock": false], forKey: AppAccessSettings.defaultsKey)
        settings.reload()
        XCTAssertEqual(settings.preferences, .init(showInMenuBar: true, showInDock: false))
        defaults.set(["showInMenuBar": false, "showInDock": false], forKey: AppAccessSettings.defaultsKey)
        settings.reload()
        XCTAssertEqual(settings.preferences, .defaults)
        XCTAssertEqual(defaults.dictionary(forKey: AppAccessSettings.defaultsKey)?["showInDock"] as? Bool, true)
    }

    private func settings() -> (AppAccessSettings, UserDefaults) {
        let name = "local.codex-dictation-tests.access.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (AppAccessSettings(defaults: defaults), defaults)
    }

    func testAllModesPersistWithoutAllowingBothOff() {
        let (settings, defaults) = settings()
        XCTAssertEqual(settings.preferences, .defaults)
        for mode in [AppAccessPreferences(showInMenuBar: true, showInDock: true),
                     .init(showInMenuBar: true, showInDock: false), .defaults] {
            XCTAssertTrue(settings.set(mode))
            XCTAssertEqual(AppAccessSettings(defaults: defaults).preferences, mode)
            XCTAssertFalse(settings.set(.init(showInMenuBar: false, showInDock: false)))
            XCTAssertEqual(settings.preferences, mode)
        }
        settings.setDock(false)
        XCTAssertEqual(settings.preferences, .defaults)
        settings.setMenuBar(true)
        settings.setDock(false)
        settings.setMenuBar(false)
        XCTAssertEqual(settings.preferences, .init(showInMenuBar: true, showInDock: false))
    }

    func testInvalidSavedSettingsRepairToExistingDefaults() {
        let (_, defaults) = settings()
        defaults.set(["showInMenuBar": false, "showInDock": false], forKey: AppAccessSettings.defaultsKey)
        XCTAssertEqual(AppAccessSettings(defaults: defaults).preferences, .defaults)
        XCTAssertEqual(defaults.dictionary(forKey: AppAccessSettings.defaultsKey)?["showInDock"] as? Bool, true)
    }

    func testRapidTransitionsAlwaysLeaveANativeEntryAndDoNotOpenWindows() {
        let (settings, _) = settings()
        var menu = false, dock = true, opens = 0
        let controller = AppAccessController(settings: settings,
            setMenuVisible: { menu = $0; XCTAssertTrue(menu || dock); return true },
            setDockVisible: { dock = $0; XCTAssertTrue(menu || dock); return true },
            revealWindow: { opens += 1 }, reportFailure: { XCTFail($0) })
        controller.apply()
        for _ in 0..<100 {
            settings.setMenuBar(true)
            settings.setDock(false)
            settings.setDock(true)
            settings.setMenuBar(false)
        }
        XCTAssertFalse(menu)
        XCTAssertTrue(dock)
        XCTAssertEqual(opens, 0)
    }

    func testSystemRemovalRecoversMenuOnlyToDockAndRevealsWindow() {
        let (settings, _) = settings()
        settings.set(.init(showInMenuBar: true, showInDock: false))
        var dock = false, opens = 0
        let controller = AppAccessController(settings: settings, setMenuVisible: { _ in true },
            setDockVisible: { dock = $0; return true }, revealWindow: { opens += 1 }, reportFailure: { XCTFail($0) })
        controller.statusItemRemoved()
        XCTAssertEqual(settings.preferences, .defaults)
        XCTAssertTrue(dock)
        XCTAssertEqual(opens, 1)
        controller.statusItemRemoved()
        XCTAssertEqual(opens, 1)
    }

    func testUnavailableStatusItemRestoresDockWithoutPersistingUnreachableMode() {
        let (settings, _) = settings()
        settings.set(.init(showInMenuBar: true, showInDock: false))
        var dock = false, failures = 0
        let controller = AppAccessController(settings: settings, setMenuVisible: { !$0 },
            setDockVisible: { dock = $0; return true }, revealWindow: {}, reportFailure: { _ in failures += 1 })
        controller.apply()
        XCTAssertTrue(dock)
        XCTAssertEqual(settings.preferences, .defaults)
        XCTAssertEqual(failures, 1)
    }

    func testDeniedDockHidingKeepsDockAvailable() {
        let (settings, _) = settings()
        settings.set(.init(showInMenuBar: true, showInDock: false))
        var failures = 0
        let controller = AppAccessController(settings: settings, setMenuVisible: { _ in true },
            setDockVisible: { $0 }, revealWindow: {}, reportFailure: { _ in failures += 1 })
        controller.apply()
        XCTAssertEqual(settings.preferences, .defaults)
        XCTAssertEqual(failures, 1)
    }
}

@MainActor
final class LibraryLifecycleTests: XCTestCase {
    func testNativeClosedWindowCanRebuildContentWithItsExistingStateOffscreen() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let name = "local.codex-dictation-tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppAccessSettings(defaults: defaults)
        let state = AppState(layout: fixture.layout, sourceURL: fixture.source, accessSettings: settings)
        state.section = .settings
        state.selectedRecordID = "preserved-selection"
        var closedWindows = 0
        let controller = LibraryWindowController(state: state, restoreWindowState: false,
            selected: { _ in }, closed: { _ in closedWindows += 1 })
        let window = try XCTUnwrap(controller.window)
        for menuEnabled in [false, true] {
            settings.setMenuBar(menuEnabled)
            controller.prepareForPresentation()
            XCTAssertNotNil(window.contentView)
            XCTAssertFalse(window.isVisible, "This test must stay offscreen")
            if controller.windowShouldClose(window) { window.close() }
            XCTAssertNil(window.contentView)
            XCTAssertEqual(closedWindows, 1, "Only a native close retires the window; menu-bar hiding keeps it reusable")
            controller.prepareForPresentation()
            XCTAssertNotNil(window.contentView)
            XCTAssertTrue(controller.window === window)
            XCTAssertEqual(state.selectedRecordID, "preserved-selection")
            XCTAssertEqual(state.section, .settings)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.statusURL.path),
                           "Opening and closing a view must not start a scan or helper")
        }
        window.close()
    }

    func testExplicitLaunchAndReopenStartServicesOnlyOnce() {
        let lifecycle = FakeLifecycle()
        let delegate = LabApplicationDelegate(lifecycle: lifecycle)
        let finished = Notification(name: NSApplication.didFinishLaunchingNotification)
        delegate.applicationDidFinishLaunching(finished)
        delegate.applicationDidFinishLaunching(finished)
        for visible in [false, true, false] {
            XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: visible))
        }
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.opens, 4)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testBackgroundLaunchStaysQuietUntilExplicitReopen() {
        let lifecycle = FakeLifecycle()
        let delegate = LabApplicationDelegate(backgroundLaunch: true, lifecycle: lifecycle)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.opens, 0)
        delegate.requestOpen()
        XCTAssertEqual(lifecycle.opens, 1)
    }

    func testHandoffDuringInitializationWaitsForWindowAcceptance() async {
        let lifecycle = FakeLifecycle()
        let delegate = LabApplicationDelegate(backgroundLaunch: true, lifecycle: lifecycle)
        let acknowledgement = expectation(description: "Open accepted after initialization")
        delegate.requestOpen { acknowledgement.fulfill() }
        XCTAssertEqual(lifecycle.opens, 0)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [acknowledgement], timeout: 1)
        XCTAssertEqual(lifecycle.opens, 1)
        XCTAssertEqual(lifecycle.starts, 1)
    }

    func testLoginAndServiceLaunchEventsAreBackground() {
        for kind in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass, eventID: kAEOpenApplication,
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: kind), forKeyword: keyAEPropData)
            XCTAssertTrue(LabApplicationDelegate.isBackgroundEvent(event))
        }
        XCTAssertFalse(LabApplicationDelegate.isBackgroundEvent(nil))
    }

    func testOpenReusesMostRecentWindowAndNewWindowRemainsExplicit() {
        var created: [FakeLibraryWindow] = []
        let coordinator = LibraryWindowCoordinator {
            let window = FakeLibraryWindow(); created.append(window); return window
        }
        coordinator.open()
        for _ in 0..<10 { coordinator.open() }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].opens, 11)
        coordinator.newWindow()
        XCTAssertEqual(created.count, 2)
        coordinator.selected(created[0])
        coordinator.open()
        XCTAssertEqual(created[0].opens, 12)
        XCTAssertEqual(created[1].opens, 1)
        coordinator.recoverDisplays()
        XCTAssertEqual(created.map(\.recoveries), [1, 1])
    }

    func testDisplayRecoveryPreservesUsableFramesAndMovesDisconnectedOnes() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let valid = NSRect(x: 100, y: 100, width: 1100, height: 750)
        XCTAssertEqual(LibraryWindowGeometry.recovered(valid, screens: [screen]), valid)
        let lost = NSRect(x: -5554, y: 2917, width: 1800, height: 1200)
        let recovered = LibraryWindowGeometry.recovered(lost, screens: [screen])
        XCTAssertTrue(screen.contains(recovered))
        XCTAssertEqual(LibraryWindowGeometry.recovered(lost, screens: []), lost)
        let second = NSRect(x: -2000, y: 0, width: 2000, height: 1400)
        let otherDisplay = NSRect(x: -1800, y: 200, width: 1180, height: 760)
        XCTAssertEqual(LibraryWindowGeometry.recovered(otherDisplay, screens: [screen, second]), otherDisplay)
    }

    func testReopenCreatesFreshWindowAfterLastWindowCloses() {
        var created: [FakeLibraryWindow] = []
        let coordinator = LibraryWindowCoordinator {
            let window = FakeLibraryWindow(); created.append(window); return window
        }
        coordinator.newWindow()
        coordinator.closed(created[0])
        coordinator.open()
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[0].opens, 1)
        XCTAssertEqual(created[1].opens, 1)
    }

    func testClosingRecentWindowReusesRemainingWindowAndIgnoresStaleSelection() {
        var created: [FakeLibraryWindow] = []
        let coordinator = LibraryWindowCoordinator {
            let window = FakeLibraryWindow(); created.append(window); return window
        }
        coordinator.newWindow()
        coordinator.newWindow()
        coordinator.closed(created[1])
        coordinator.selected(created[1])
        coordinator.open()
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[0].opens, 2)
        XCTAssertEqual(created[1].opens, 1)
    }
}

@MainActor private final class FakeLifecycle: LibraryApplicationLifecycle {
    var starts = 0, opens = 0
    func start() { starts += 1 }
    func openMain() { opens += 1 }
}

@MainActor private final class FakeLibraryWindow: LibraryWindow {
    var opens = 0, recoveries = 0
    func present() { opens += 1 }
    func recoverDisplay() { recoveries += 1 }
}
