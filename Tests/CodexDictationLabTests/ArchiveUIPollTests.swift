import Combine
import Foundation
import ServiceManagement
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

@MainActor
final class ArchiveUIPollTests: XCTestCase {
    func testHealthyUnchangedPollsPublishNothingAndHeartbeatDoesNotRebuildArchiveUI() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let reads = UIPollReadCounter()
        let manager = LoginItemManager(service: UIPollLoginService(), helperRunning: { true })
        let state = AppState(layout: f.layout, sourceURL: f.source,
            afterSnapshot: { await reads.increment() }, loginItemManager: manager)
        await state.refreshArchive()
        await state.refreshArchive()
        _ = state.dailyActivity
        let initialReads = await reads.value
        let initialComputations = state.dailyActivityComputationCount
        var notifications = 0, archivePublications = 0, healthPublications = 0
        var subscriptions = Set<AnyCancellable>()
        state.objectWillChange.sink { notifications += 1 }.store(in: &subscriptions)
        state.$records.dropFirst().sink { _ in archivePublications += 1 }.store(in: &subscriptions)
        state.$recordsRevision.dropFirst().sink { _ in archivePublications += 1 }.store(in: &subscriptions)
        state.$statistics.dropFirst().sink { _ in archivePublications += 1 }.store(in: &subscriptions)
        state.$captureHealth.dropFirst().sink { _ in healthPublications += 1 }.store(in: &subscriptions)
        for _ in 0..<10 { await state.refreshArchive(); _ = state.dailyActivity }
        XCTAssertEqual(notifications, 0, "Equal flags/status values must not invalidate the whole observable model")
        XCTAssertEqual(archivePublications, 0)
        XCTAssertEqual(healthPublications, 0)
        let unchangedReads = await reads.value
        XCTAssertEqual(unchangedReads, initialReads)
        XCTAssertEqual(state.dailyActivityComputationCount, initialComputations)

        let old = try XCTUnwrap(state.captureHealth)
        let next = CaptureHealthSnapshot(process: old.process, processID: old.processID,
            captureEnabled: old.captureEnabled, isPaused: old.isPaused, sourceAvailable: old.sourceAvailable,
            sourceRecordCount: old.sourceRecordCount, archiveRecordCount: old.archiveRecordCount,
            lastScanAt: old.lastScanAt.addingTimeInterval(1), lastCaptureAt: old.lastCaptureAt, lastError: nil)
        try CaptureStatusStore(layout: f.layout).save(next)
        await state.refreshArchive()
        XCTAssertEqual(state.captureHealth, next)
        XCTAssertEqual(healthPublications, 1, "A genuinely new heartbeat remains live")
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(archivePublications, 0)
        _ = state.dailyActivity
        XCTAssertEqual(state.dailyActivityComputationCount, initialComputations)
        let heartbeatReads = await reads.value
        XCTAssertEqual(heartbeatReads, initialReads)
        await state.refreshArchive()
        XCTAssertEqual(notifications, 1, "The same heartbeat is not republished")
    }

    func testMidnightAndTimezoneInvalidateOnceAndRebucketCorrectly() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let folder = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        let formatter = ISO8601DateFormatter()
        let recorded = formatter.date(from: "2026-10-20T23:30:00Z")!
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("metadata.json"))) as! [String: Any]
        metadata["createdAtMs"] = recorded.timeIntervalSince1970 * 1000
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        _ = try f.engine.scan()
        var now = formatter.date(from: "2026-10-21T21:59:59Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let manager = LoginItemManager(service: UIPollLoginService(), helperRunning: { true })
        let state = AppState(layout: f.layout, sourceURL: f.source,
            now: { now }, currentCalendar: { calendar }, loginItemManager: manager)
        await state.refreshArchive(); await state.refreshArchive()
        let before = state.dailyActivity
        XCTAssertEqual(before.last?.recordingCount, 1)
        XCTAssertEqual(state.dailyActivityComputationCount, 1)
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        now = formatter.date(from: "2026-10-21T22:00:01Z")!
        await state.refreshArchive()
        XCTAssertEqual(notifications, 1, "Midnight invalidates the cached calendar once even without a new heartbeat")
        XCTAssertEqual(state.dailyActivityComputationCount, 1, "Invalidation stays lazy")
        let midnight = state.dailyActivity
        XCTAssertEqual(midnight.last?.day, calendar.startOfDay(for: now))
        XCTAssertEqual(midnight.last?.recordingCount, 0)
        XCTAssertEqual(midnight.first?.day, calendar.date(byAdding: .day, value: 1, to: before[0].day))
        XCTAssertEqual(state.dailyActivityComputationCount, 2)
        await state.refreshArchive()
        XCTAssertEqual(notifications, 1)

        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        await state.refreshArchive()
        let relocated = state.dailyActivity
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(relocated.last?.day, calendar.startOfDay(for: now))
        XCTAssertEqual(relocated.first(where: { $0.day == calendar.startOfDay(for: recorded) })?.recordingCount, 1)
        XCTAssertEqual(state.dailyActivityComputationCount, 3)
    }

    func testRecordRevisionAndDSTCalendarDaysRemainCorrect() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let cache = DailyActivityCache()
        XCTAssertEqual(cache.value(records: [record], revision: 1, now: record.createdAt, calendar: calendar).last?.recordingCount, 1)
        XCTAssertEqual(cache.value(records: [], revision: 2, now: record.createdAt, calendar: calendar).last?.recordingCount, 0)
        XCTAssertEqual(cache.computationCount, 2)
        let now = ISO8601DateFormatter().date(from: "2026-03-30T12:00:00Z")!
        let rows = cache.value(records: [], revision: 2, now: now, calendar: calendar)
        XCTAssertEqual(rows.count, 30)
        XCTAssertEqual(Set(rows.map(\.day)).count, 30)
        XCTAssertTrue(zip(rows, rows.dropFirst()).contains { pair in pair.1.day.timeIntervalSince(pair.0.day) == 23 * 3600 })
    }

    func testSynchronousObserverCannotCacheOldRowsUnderNewRevision() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        let manager = LoginItemManager(service: UIPollLoginService(), helperRunning: { true })
        let state = AppState(layout: f.layout, sourceURL: f.source, now: { record.createdAt }, loginItemManager: manager)
        await state.refreshArchive(); await state.refreshArchive()
        XCTAssertEqual(state.dailyActivity.last?.recordingCount, 1)
        let subscription = state.objectWillChange.sink { _ = state.dailyActivity }
        defer { subscription.cancel() }
        try f.store.softDelete(id: record.id)
        await state.refreshArchive()
        XCTAssertEqual(state.dailyActivity.last?.recordingCount, 0)
        XCTAssertEqual(state.dailyActivityComputationCount, 2)
    }
}

private actor UIPollReadCounter {
    var value = 0
    func increment() { value += 1 }
}

@MainActor
private final class UIPollLoginService: LoginItemService {
    var status: SMAppService.Status { .enabled }
    func register() throws { XCTFail("Read-only polling must not register") }
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) { XCTFail("Read-only polling must not unregister") }
}
