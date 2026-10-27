import Foundation
import XCTest
@testable import DictationArchiveCore

final class CaptureStateStoresTests: XCTestCase {
    func testIsolatedSettingsSaveDoesNotNotifyTheInstalledHelper() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let notification = NotificationProbe()
        let store = CaptureSettingsStore(layout: fixture.layout) { notification.record() }
        let settings = CaptureSettings(captureEnabled: false, isPaused: true, launchAtLoginRequested: false)
        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(notification.count, 0)
    }

    func testSettingsDefaultAndExactRoundTrip() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = CaptureSettingsStore(layout: fixture.layout)
        XCTAssertEqual(store.load(), .default)

        let settings = CaptureSettings(
            captureEnabled: false,
            isPaused: true,
            launchAtLoginRequested: false
        )
        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: fixture.layout.settingsURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testHealthSnapshotRoundTrip() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = CaptureStatusStore(layout: fixture.layout)
        let snapshot = CaptureHealthSnapshot(
            process: .helper,
            processID: 42,
            captureEnabled: true,
            isPaused: false,
            sourceAvailable: true,
            sourceRecordCount: 20,
            archiveRecordCount: 57,
            lastScanAt: Date(timeIntervalSince1970: 100),
            lastCaptureAt: Date(timeIntervalSince1970: 90),
            lastError: nil
        )

        try store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }
}

private final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        recordedCount += 1
    }
}
