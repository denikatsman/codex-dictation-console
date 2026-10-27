import Foundation
import XCTest
@testable import DictationArchiveCore

final class CaptureHelperLifetimeTests: XCTestCase {
    func testDuplicateCannotOwnMonitorUntilIncumbentReleasesOwnership() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ArchiveLayout(applicationSupportURL: root)
        var owner = try CaptureHelperLifetime.acquire(layout: layout)
        XCTAssertNotNil(owner)
        XCTAssertNil(try CaptureHelperLifetime.acquire(layout: layout))
        withExtendedLifetime(owner) {}
        owner = nil

        let replacement = try XCTUnwrap(CaptureHelperLifetime.acquire(layout: layout))
        XCTAssertNil(try CaptureHelperLifetime.acquire(layout: layout))
        withExtendedLifetime(replacement) {}
    }

    func testLifetimeOwnershipAllowsArchiveScansAndFinalMonitorDrain() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try XCTUnwrap(CaptureHelperLifetime.acquire(layout: fixture.layout))
        let initialScan = expectation(description: "initial archive scan finishes while helper owns lifetime")
        let firstResult = LifetimeOneShotFlag()
        let monitor = CaptureMonitor(engine: fixture.engine) { result in
            guard firstResult.claim() else { return }
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            initialScan.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }
        wait(for: [initialScan], timeout: 2)

        _ = try fixture.makeSourceRecording(
            sourceKey: "final-capture", id: "final-capture", transcript: "Preserved before helper exits",
            chunks: [Data("synthetic audio".utf8)], status: "recording"
        )
        monitor.stop(capturePendingChanges: true)
        XCTAssertEqual(
            try fixture.store.record(id: "final-capture")?.transcript,
            "Preserved before helper exits"
        )
        XCTAssertNil(try CaptureHelperLifetime.acquire(layout: fixture.layout))
        withExtendedLifetime(owner) {}
    }

    func testOwnershipIsExclusiveAcrossProcessesAndReleasesWithoutDeletingLockFile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ArchiveLayout(applicationSupportURL: root)
        let lockURL = CaptureHelperLifetime.lockURL(in: layout)
        var owner = try CaptureHelperLifetime.acquire(layout: layout)
        XCTAssertNotNil(owner)
        XCTAssertEqual(try probeOwnership(at: lockURL), 23, "Another process must observe the incumbent lock")
        withExtendedLifetime(owner) {}
        owner = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertEqual(try probeOwnership(at: lockURL), 0, "A subsequent process can claim the retained lock file")
    }

    func testFilesystemFailureIsNotMistakenForAnExistingHelper() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        XCTAssertThrowsError(try CaptureHelperLifetime.acquire(layout: ArchiveLayout(applicationSupportURL: root)))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CaptureHelperLifetime-\(UUID().uuidString)")
    }

    private func probeOwnership(at lockURL: URL) throws -> Int32 {
        // A separate process verifies the actual OS advisory lock boundary,
        // without launching the app, its helper, or touching the real archive.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MFcntl=:flock,:DEFAULT", "-e", """
            sysopen(my $lock, $ARGV[0], O_RDWR | O_CREAT, 0600) or die "open: $!";
            exit 0 if flock($lock, LOCK_EX | LOCK_NB);
            exit($!{EWOULDBLOCK} ? 23 : 24);
            """, lockURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        return process.terminationStatus
    }
}

private final class LifetimeOneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
