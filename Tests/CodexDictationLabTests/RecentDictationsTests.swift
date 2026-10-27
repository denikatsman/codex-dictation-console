import AppKit
import Combine
import SwiftUI
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

final class RecentDictationsDataTests: XCTestCase {
    func testLatestTenAreOrderedAndExcludeDeletedAndUnfinishedRecords() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for index in 0..<16 {
            let folder = try f.makeSourceRecording(sourceKey: "source-\(index)", id: "\(index)",
                transcript: "Words \(index)", chunks: [Data("audio".utf8)],
                status: index == 15 ? "recording" : "completed")
            let url = folder.appendingPathComponent("metadata.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            json["createdAtMs"] = 1_788_000_000_000 + index * 1_000
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        _ = try f.engine.scan()
        try f.store.softDelete(id: "14")
        XCTAssertEqual(try f.store.latestFinishedRecords().map(\.id), (4...13).reversed().map(String.init))
        XCTAssertEqual(try f.store.latestFinishedRecords(limit: 1).map(\.id), ["13"])
        XCTAssertThrowsError(try f.store.latestFinishedRecords(limit: 0))
        XCTAssertThrowsError(try f.store.latestFinishedRecords(limit: 101))
    }

    func testFullTextAndOriginalMillisecondTimestampSurviveWithoutTruncation() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let exact = "  Beginning\n\n" + String(repeating: "Café — русский 👋\n", count: 1_000) + "END  "
        let folder = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: exact, chunks: [Data("audio".utf8)])
        let url = folder.appendingPathComponent("metadata.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["createdAtMs"] = 1_000_123
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        _ = try f.engine.scan()
        let before = try f.snapshot(folder: folder)
        let row = try XCTUnwrap(DictationLogEntry.load(store: f.store, timeZone: TimeZone(secondsFromGMT: 7_200)!).first)
        XCTAssertEqual(row.text, exact)
        XCTAssertEqual(row.recordedAt.timeIntervalSince1970, 1_000.123, accuracy: 0.0001)
        XCTAssertEqual(row.timestamp, "1970-01-01  ·  02:16:40.123 +02:00")
        XCTAssertFalse(row.recovered)
        XCTAssertEqual(try f.snapshot(folder: folder), before, "Reading the log cannot rewrite the source")
    }

    func testRecoveryIsLabelledAndOnlyUsedWhenOriginalTextIsEmpty() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for (id, text) in [("original", "Original exact words"), ("empty", "")] {
            _ = try f.makeSourceRecording(sourceKey: id, id: id, transcript: text, chunks: [Data("audio".utf8)], status: "cancelled")
        }
        _ = try f.engine.scan()
        for id in ["original", "empty"] {
            let record = try XCTUnwrap(f.store.record(id: id))
            for index in 1...2 {
                _ = try TranscriptRecoveryStore(store: f.store).save(RecoveredTranscript(recordID: id,
                    audioSHA256: record.audioSHA256!, localeIdentifier: "en_US", text: "Recovered \(index)",
                    createdAt: Date(timeIntervalSince1970: Double(index))))
            }
        }
        let entries = try DictationLogEntry.load(store: f.store)
        let original = try XCTUnwrap(entries.first { $0.id == "original" })
        let recovered = try XCTUnwrap(entries.first { $0.id == "empty" })
        XCTAssertEqual(original.text, "Original exact words")
        XCTAssertFalse(original.recovered)
        XCTAssertEqual(recovered.text, "Recovered 2")
        XCTAssertTrue(recovered.recovered)
        XCTAssertTrue(recovered.partial)
        XCTAssertEqual(try f.store.record(id: "empty")?.transcript, "")
    }
}

@MainActor
final class RecentDictationsLifecycleTests: XCTestCase {
    func testArchiveNotificationUpdatesOpenLogAndClosedLogDoesNoWork() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = AppState(layout: f.layout, sourceURL: f.source)
        let model = RecentDictationsLogModel(store: f.store)
        defer { model.stop() }
        model.start(state: state)
        await eventually { model.hasLoaded }
        XCTAssertTrue(model.entries.isEmpty)
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Live update", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        DistributedNotificationCenter.default().postNotificationName(ArchiveStore.didChangeNotification,
            object: nil, userInfo: nil, deliverImmediately: true)
        await eventually { model.entries.first?.text == "Live update" }
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(publications, 0, "Equal archive data cannot redraw the window")
        model.stop()
        try f.store.softDelete(id: "one")
        model.refresh()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.entries.count, 1, "Closed readers ignore refreshes")
        model.start(state: state)
        await eventually { model.entries.isEmpty }
    }

    func testStoppingAndReopeningRejectsOldInFlightReadAndFailureRetainsText() async throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = AppState(layout: f.layout, sourceURL: f.source)
        let reader = LogTestReader()
        let model = RecentDictationsLogModel(store: f.store, load: { try reader.read() })
        defer { reader.releaseFirst.signal(); model.stop() }
        model.start(state: state)
        await eventually { reader.count >= 1 }
        model.stop()
        model.start(state: state)
        await eventually { model.entries.first?.text == "Current" }
        reader.releaseFirst.signal()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.entries.first?.text, "Current", "A read from the closed window cannot overwrite the new one")
        reader.fail()
        model.refresh()
        await eventually { model.error != nil }
        XCTAssertEqual(model.entries.first?.text, "Current", "A failed read must preserve the last visible words")
    }

    func testFloatingPanelClosesReopensAndDoesNotStartCapture() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = AppState(layout: f.layout, sourceURL: f.source)
        state.section = .settings
        state.selectedRecordID = "preserved"
        let controller = RecentDictationsWindowController(state: state, restoreFrame: false, openRecord: { _ in })
        defer { controller.model.stop(); controller.window?.close() }
        controller.prepareForPresentation()
        let first = try XCTUnwrap(controller.window as? NSPanel)
        XCTAssertEqual(first.level, .floating)
        XCTAssertFalse(first.hidesOnDeactivate)
        XCTAssertTrue(first.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(first.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(first.canBecomeKey, "Text selection and copy require a key window")
        XCTAssertFalse(first.isVisible, "This lifecycle test must stay offscreen")
        XCTAssertTrue(first.contentView is NSHostingView<RecentDictationsLogView>)
        first.close()
        XCTAssertNil(first.contentView)
        controller.prepareForPresentation()
        XCTAssertFalse(controller.window === first, "A natively closed SwiftUI host needs a fresh panel")
        XCTAssertTrue(controller.window?.contentView is NSHostingView<RecentDictationsLogView>)
        XCTAssertEqual(state.section, .settings)
        XCTAssertEqual(state.selectedRecordID, "preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.layout.statusURL.path))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for log update", file: file, line: line)
    }
}

private final class LogTestReader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failing = false
    let releaseFirst = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { calls } }
    func fail() { lock.withLock { failing = true } }
    func read() throws -> [DictationLogEntry] {
        let (call, shouldFail) = lock.withLock { calls += 1; return (calls, failing) }
        if call == 1 { _ = releaseFirst.wait(timeout: .now() + 10) }
        if shouldFail { throw CocoaError(.fileReadNoPermission) }
        return [DictationLogEntry(id: "one", recordedAt: .distantPast, timestamp: "time",
            text: call == 1 ? "Stale" : "Current", recovered: false, partial: false)]
    }
}
