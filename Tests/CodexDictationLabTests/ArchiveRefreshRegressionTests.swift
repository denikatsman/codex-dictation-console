import Foundation
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

@MainActor
final class ArchiveRefreshRegressionTests: XCTestCase {
    func testUnchangedHealthRefreshSkipsFullSnapshotAndDetectsExternalChanges() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let loads = SnapshotLoadCount()
        let state = AppState(layout: f.layout, sourceURL: f.source, afterSnapshot: { await loads.increment() })
        await state.refreshArchive()
        // A first read may create/checkpoint a WAL. Stabilize once, then prove
        // unchanged health polls never load or compare the whole record arrays.
        await state.refreshArchive()
        let initial = await loads.value
        let revision = state.recordsRevision
        for _ in 0..<10 { await state.refreshArchive() }
        let unchanged = await loads.value
        XCTAssertEqual(unchanged, initial)
        XCTAssertEqual(state.recordsRevision, revision)
        for _ in 0..<3 {
            _ = try f.engine.scan()
            await state.refreshArchive()
        }
        let unchangedWithWorker = await loads.value
        XCTAssertEqual(unchangedWithWorker, initial, "An unchanged worker reconciliation must not invalidate the library")
        try f.store.softDelete(id: "one")
        await state.refreshArchive()
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertEqual(state.deletedRecords.map(\.id), ["one"])
        try f.store.restore(id: "one")
        await state.refreshArchive()
        XCTAssertEqual(state.records.map(\.id), ["one"])
        let forced = await loads.value
        await state.refreshArchive(verifyFiles: true)
        let verified = await loads.value
        XCTAssertEqual(verified, forced + 1, "Explicit integrity verification always reads rows")
    }
    func testSavedLibraryIsPublishedBeforeDeepVerificationFinishes() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let gate = SnapshotGate()
        await gate.arm()
        let state = AppState(layout: f.layout, sourceURL: f.source, beforeVerification: { await gate.pauseIfArmed() })
        let refresh = Task { await state.refreshArchive() }
        try await gate.waitForSnapshot()
        XCTAssertEqual(state.records.map(\.id), ["one"])
        XCTAssertTrue(state.hasLoadedArchive)
        XCTAssertFalse(state.isLoadingArchive)
        XCTAssertTrue(state.isVerifyingArchive)
        XCTAssertNil(state.archiveVerification)
        await gate.release()
        await refresh.value
        XCTAssertEqual(state.archiveVerification?.verifiedRecordCount, 1)
        XCTAssertFalse(state.isVerifyingArchive)
    }

    func testFailedVerificationDoesNotHideLoadedHistoryOrReplaceDatabaseCheck() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let gate = SnapshotGate()
        await gate.arm()
        let state = AppState(layout: f.layout, sourceURL: f.source, beforeVerification: { await gate.pauseIfArmed() })
        let refresh = Task { await state.refreshArchive(showErrors: false) }
        try await gate.waitForSnapshot()
        try Data("damaged fixture index".utf8).write(to: f.layout.databaseURL, options: .atomic)
        await gate.release()
        await refresh.value
        XCTAssertEqual(state.records.map(\.id), ["one"])
        XCTAssertEqual(state.archiveIntegrity, "ok")
        XCTAssertNil(state.archiveLoadError)
        XCTAssertNotNil(state.archiveVerificationError)

        await state.refreshArchive(showErrors: false)
        XCTAssertEqual(state.records.map(\.id), ["one"])
        XCTAssertNotNil(state.archiveLoadError)
    }

    func testSettingsLockWaitKeepsMainActorAvailable() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = AppState(layout: f.layout, sourceURL: f.source)
        let locked = expectation(description: "Archive lock held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holder = Task.detached {
            try ArchiveLock.withExclusiveAccess(to: f.layout) {
                locked.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        await fulfillment(of: [locked], timeout: 2)
        let save = Task { await state.setPaused(true) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(state.isSavingSettings, "The main actor must be reachable while settings wait for the lock")
        release.signal()
        try await holder.value
        await save.value
        XCTAssertFalse(state.isSavingSettings)
        XCTAssertTrue(state.captureSettings.isPaused)
    }

    func testBusyExportRejectsDuplicatesAndClearsItsStateAfterCompletion() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let state = AppState(layout: f.layout, sourceURL: f.source)
        let locked = expectation(description: "Archive lock held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holder = Task.detached {
            try ArchiveLock.withExclusiveAccess(to: f.layout) {
                locked.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        await fulfillment(of: [locked], timeout: 2)
        let destination = f.root.appendingPathComponent("Export")
        let export = Task { await state.export(recordID: "one", to: destination) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(state.isExporting)
        let duplicate = await state.exportAll(to: destination)
        XCTAssertNil(duplicate)
        release.signal()
        try await holder.value
        let exported = await export.value
        XCTAssertNotNil(exported)
        XCTAssertFalse(state.isExporting)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
        let failed = await state.export(recordID: "missing", to: destination)
        XCTAssertNil(failed)
        XCTAssertFalse(state.isExporting)
    }

    func testCDL005023CacheCleanupFailureKeepsDeletionRetryable() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        try f.store.softDelete(id: "one")
        let cache = f.root.appendingPathComponent("Cache")
        let folder = cache.appendingPathComponent(DictationCaptureEngine.sha256(Data("one".utf8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocked = folder.appendingPathComponent("playback.m4a")
        try Data("derived audio".utf8).write(to: blocked)
        XCTAssertEqual(chflags(blocked.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(blocked.path, 0) }
        let state = AppState(layout: f.layout, sourceURL: f.source, playbackAssets: NativePlaybackAssetStore(cacheDirectory: cache))
        await state.permanentlyDelete(id: "one")
        XCTAssertNotNil(try f.store.record(id: "one"))
        XCTAssertTrue(state.alertMessage?.contains("incomplete") == true)
        XCTAssertEqual(chflags(blocked.path, 0), 0)
        await state.permanentlyDelete(id: "one")
        XCTAssertNil(try f.store.record(id: "one"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCDL017ContentRevisionChangesWhenCountAndNewestTimestampDoNot() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.makeSourceRecording(sourceKey: "a", id: "a", transcript: "Old a", chunks: [Data("audio".utf8)])
        let b = try f.makeSourceRecording(sourceKey: "b", id: "b", transcript: "Old b", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan(now: Date(timeIntervalSince1970: 100))
        let state = AppState(layout: f.layout, sourceURL: f.source)
        await state.refreshArchive()
        try f.writeMetadata(to: a, id: "a", transcript: "Match a", size: 5)
        _ = try f.engine.scan(now: Date(timeIntervalSince1970: 200))
        await state.refreshArchive()
        let before = state.recordsRevision
        let maximum = state.records.map(\.updatedAt).max()
        try f.writeMetadata(to: b, id: "b", transcript: "Match b", size: 5)
        _ = try f.engine.scan(now: Date(timeIntervalSince1970: 200))
        await state.refreshArchive()
        XCTAssertEqual(state.records.count, 2)
        XCTAssertEqual(state.records.map(\.updatedAt).max(), maximum)
        XCTAssertGreaterThan(state.recordsRevision, before)
        let matches = await state.searchArchive("Match")
        XCTAssertEqual(matches.count, 2)
    }

    func testCDL018FailedSourceScanStillLoadsSavedArchive() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let unavailable = f.root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: unavailable)
        let state = AppState(layout: f.layout, sourceURL: unavailable)
        await state.refreshArchive(scanSource: true)
        XCTAssertEqual(state.records.map(\.id), ["one"])
        XCTAssertNotNil(state.alertMessage)
        XCTAssertNotNil(state.captureHealth?.lastError)
        XCTAssertEqual(state.archiveIntegrity, "ok")
    }

    func testCDL026MutationWaitsForFreshSnapshotAndBusyVerificationIsNotDropped() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let gate = SnapshotGate()
        let state = AppState(layout: f.layout, sourceURL: f.source, afterSnapshot: { await gate.pauseIfArmed() })
        await state.refreshArchive()
        let checkedAt = state.archiveVerification?.checkedAt
        await gate.arm()
        // Force a changed database stamp so this test still pauses a real row
        // load rather than the new unchanged-health fast path.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)],
            ofItemAtPath: f.layout.databaseURL.path)
        let staleRefresh = Task { await state.refreshArchive() }
        try await gate.waitForSnapshot()
        let mutation = Task { await state.moveToRecentlyDeleted(id: "one") }
        for _ in 0..<200 {
            if try f.store.recordCount(deleted: true) == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stronger = Task { await state.refreshArchive(scanSource: true, verifyFiles: true) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release()
        await mutation.value
        await staleRefresh.value
        await stronger.value
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertEqual(state.deletedRecords.map(\.id), ["one"])
        XCTAssertNotEqual(state.archiveVerification?.checkedAt, checkedAt)
        XCTAssertFalse(state.isLoadingArchive)
    }
}

private actor SnapshotLoadCount {
    var value = 0
    func increment() { value += 1 }
}

private actor SnapshotGate {
    private var armed = false
    private var pending: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { pending = $0 }
    }
    func waitForSnapshot() async throws {
        for _ in 0..<200 {
            if pending != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SnapshotGate", code: 1)
    }
    func release() { pending?.resume(); pending = nil }
}
