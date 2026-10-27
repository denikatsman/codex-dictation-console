import Foundation
import ServiceManagement
import XCTest
@testable import CodexDictationLab

@MainActor
final class HelperStartupTests: XCTestCase {
    func testReadbackTracksExternalChangesWithoutRegistering() {
        let service = TestStartupService()
        let manager = LoginItemManager(service: service)
        for (native, expected) in [(SMAppService.Status.enabled, LoginItemState.enabled),
                                   (.notRegistered, .disabled), (.requiresApproval, .requiresApproval)] {
            service.status = native
            XCTAssertEqual(manager.state(), expected)
        }
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testExplicitEnableMigratesLegacyLoginOnlyAfterMainRegistration() async throws {
        let main = TestStartupService()
        let legacy = TestStartupService(); legacy.status = .enabled
        var stopped = false
        let manager = LoginItemManager(service: main, legacyService: legacy, helperRunning: { true }, stopHelper: { stopped = true })
        let enabled = try await manager.setEnabled(true)
        XCTAssertEqual(enabled, .enabled)
        XCTAssertEqual(main.registrations, 1)
        XCTAssertEqual(legacy.unregistrations, 1)
        XCTAssertTrue(stopped, "Drain a legacy service-owned worker before removing its job")
        _ = try await manager.setEnabled(true)
        XCTAssertEqual(main.registrations, 1)
    }

    func testApprovalDenialIsNeverResetAndLegacyStaysUntilAppApproved() async throws {
        let main = TestStartupService(); main.status = .requiresApproval
        let legacy = TestStartupService(); legacy.status = .enabled
        let manager = LoginItemManager(service: main, legacyService: legacy)
        for _ in 0..<3 {
            let state = try await manager.setEnabled(true)
            XCTAssertEqual(state, .requiresApproval)
        }
        XCTAssertEqual(main.registrations, 0)
        XCTAssertEqual(main.unregistrations, 0)
        XCTAssertEqual(legacy.unregistrations, 0)
    }

    func testRegistrationFailurePreservesLegacyAndReportsError() async throws {
        let main = TestStartupService(); main.registrationFails = true
        let legacy = TestStartupService(); legacy.status = .enabled
        do { _ = try await LoginItemManager(service: main, legacyService: legacy).setEnabled(true); XCTFail("Expected registration failure") }
        catch {}
        XCTAssertEqual(legacy.status, .enabled)
        XCTAssertEqual(legacy.unregistrations, 0)
    }

    func testExplicitDisableRetiresBothLoginRegistrationsWithoutChangingCapture() async throws {
        let main = TestStartupService(); main.status = .enabled
        let legacy = TestStartupService(); legacy.status = .enabled
        let manager = LoginItemManager(service: main, legacyService: legacy, helperRunning: { true })
        let disabled = try await manager.setEnabled(false)
        XCTAssertEqual(disabled, .disabled)
        XCTAssertEqual(main.unregistrations, 1)
        XCTAssertEqual(legacy.unregistrations, 1)
        XCTAssertTrue(manager.isHelperRunning)
    }

    func testManualCaptureAfterExternalRemovalDoesNotRestoreLogin() async throws {
        let service = TestStartupService(); service.status = .enabled
        var running = false
        let manager = LoginItemManager(service: service, launchHelper: { running = true }, helperRunning: { running })
        service.status = .notRegistered
        try await manager.launchHelper()
        XCTAssertTrue(running)
        XCTAssertEqual(manager.state(), .disabled)
        XCTAssertEqual(service.registrations, 0)
    }

    func testOverlappingManualRequestsShareOneWorker() async throws {
        let service = TestStartupService()
        let entered = expectation(description: "Opening worker")
        var release: CheckedContinuation<Void, Never>?
        var running = false, opens = 0
        let manager = LoginItemManager(service: service, launchHelper: {
            opens += 1
            await withCheckedContinuation { release = $0; entered.fulfill() }
            running = true
        }, helperRunning: { running })
        let first = Task { try await manager.launchHelper() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await manager.launchHelper() }
        release?.resume()
        try await first.value; try await second.value
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(service.registrations, 0)
    }

    func testQuitSuppressesQueuedStartsAndWaitsForWorkerDrain() async throws {
        let service = TestStartupService()
        var quitting = true, stopped = false, opens = 0
        let manager = LoginItemManager(service: service, launchHelper: { opens += 1 },
            stopHelper: { stopped = true }, isQuitting: { quitting })
        try await manager.launchHelper()
        _ = try await manager.setEnabled(true)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(service.registrations, 0)
        try await manager.stopHelperForQuit()
        XCTAssertTrue(stopped)
        quitting = false
    }
}

@MainActor
private final class TestStartupService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0, unregistrations = 0
    var registrationFails = false
    func register() throws {
        registrations += 1
        if registrationFails { throw CocoaError(.userCancelled) }
        status = .enabled
    }
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) {
        unregistrations += 1
        status = .notRegistered
        completionHandler(nil)
    }
}
