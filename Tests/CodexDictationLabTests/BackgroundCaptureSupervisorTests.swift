import Foundation
import XCTest
@testable import CodexDictationLab
@testable import DictationArchiveCore

@MainActor
final class BackgroundCaptureSupervisorTests: XCTestCase {
    func testMissingHelperRelaunchesWithoutAWindowOrLoginRegistration() async {
        let fixture = SupervisorFixture()
        fixture.running = false
        fixture.recent = false
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.scans, [true])
    }

    func testStaleButRunningHelperGetsFallbackWithoutBeingKilled() async {
        let fixture = SupervisorFixture()
        fixture.recent = false
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.scans, [true])
    }

    func testHealthyHelperAvoidsDuplicateScanning() async {
        let fixture = SupervisorFixture()
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.scans, [false])
        XCTAssertEqual(fixture.launchCount, 0)
    }

    func testDisabledCaptureDoesNotRelaunchOrScanSource() async {
        let fixture = SupervisorFixture()
        fixture.enabled = false
        fixture.running = false
        fixture.recent = false
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.scans, [false])
    }

    func testLaunchFailureIsVisibleAndStillFallsBackThenRecovers() async {
        let fixture = SupervisorFixture()
        fixture.running = false
        fixture.launchFails = true
        await fixture.supervisor.check()
        XCTAssertNotNil(fixture.error)
        XCTAssertEqual(fixture.scans, [true])
        fixture.launchFails = false
        fixture.now = fixture.now.addingTimeInterval(10)
        await fixture.supervisor.check()
        XCTAssertNil(fixture.error)
        XCTAssertTrue(fixture.running)
    }

    func testIntentionalQuitDoesNotResurrectTheHelper() async {
        let fixture = SupervisorFixture()
        fixture.running = false
        fixture.quitting = true
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertTrue(fixture.scans.isEmpty)
    }

    func testUnavailableHelperUsesBoundedBackoffWhileFallbackContinues() async {
        let fixture = SupervisorFixture()
        fixture.running = false; fixture.recent = false; fixture.launchFails = true
        for _ in 0..<5 { await fixture.supervisor.check() }
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.scans, Array(repeating: true, count: 5))
        fixture.now = fixture.now.addingTimeInterval(10)
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 2)
        fixture.now = fixture.now.addingTimeInterval(19)
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 2)
    }

    func testQuitDuringHelperLaunchDoesNotStartAFallbackScan() async {
        let fixture = SupervisorFixture()
        fixture.running = false
        fixture.quitDuringLaunch = true
        await fixture.supervisor.check()
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertTrue(fixture.scans.isEmpty)
    }

    func testFailedOrOldHeartbeatIsNotHealthy() {
        let now = Date(timeIntervalSince1970: 1000)
        func health(age: TimeInterval, error: String? = nil) -> CaptureHealthSnapshot {
            CaptureHealthSnapshot(
                process: .helper, processID: 123, captureEnabled: true, isPaused: false,
                sourceAvailable: true, sourceRecordCount: 1, archiveRecordCount: 1,
                lastScanAt: now.addingTimeInterval(-age), lastCaptureAt: nil, lastError: error
            )
        }
        XCTAssertTrue(health(age: 15).isRecentAndHealthy(now: now))
        XCTAssertFalse(health(age: 46).isRecentAndHealthy(now: now))
        XCTAssertFalse(health(age: -100).isRecentAndHealthy(now: now))
        XCTAssertFalse(health(age: 0, error: "disk full").isRecentAndHealthy(now: now))
    }
}

@MainActor
private final class SupervisorFixture {
    var quitting = false
    var enabled = true
    var running = true
    var recent = true
    var launchCount = 0
    var launchFails = false
    var quitDuringLaunch = false
    var scans: [Bool] = []
    var error: String?
    var now = Date(timeIntervalSince1970: 1000)
    lazy var supervisor = BackgroundCaptureSupervisor(
        isQuitting: { [unowned self] in quitting },
        captureEnabled: { [unowned self] in enabled },
        helperRunning: { [unowned self] in running },
        scanIsRecent: { [unowned self] in recent },
        launchHelper: { [unowned self] in
            launchCount += 1
            if launchFails { throw CocoaError(.fileNoSuchFile) }
            if quitDuringLaunch { quitting = true }
            running = true
        },
        refresh: { [unowned self] scan in scans.append(scan) },
        reportLaunchError: { [unowned self] message in error = message },
        now: { [unowned self] in now }
    )
}
