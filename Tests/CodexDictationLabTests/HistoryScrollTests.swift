import AppKit
import DictationArchiveCore
import SwiftUI
import XCTest
@testable import CodexDictationLab

@MainActor
final class HistoryScrollTests: XCTestCase {
    func testSearchRefreshKeepsTheMountedListAndExactReadingPosition() async throws {
        let original = (0..<100).map { record($0, transcript: "Synthetic transcript \($0) for the history scroll check.") }
        let model = HistoryResultsFixtureModel(records: original)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HistoryResultsFixtureView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let table = try XCTUnwrap(descendant(NSTableView.self, in: host))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(table.numberOfRows, original.count)
        XCTAssertGreaterThan(scroll.frame.height, 400)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2_447.5))
        scroll.reflectScrolledClipView(scroll.contentView)
        let row = table.rows(in: scroll.contentView.bounds).location
        let before = table.rect(ofRow: row).minY - scroll.contentView.bounds.minY

        model.isSearching = true
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendant(NSTableView.self, in: host) === table)
        XCTAssertEqual(table.rect(ofRow: row).minY - scroll.contentView.bounds.minY, before, accuracy: 0.01)
        XCTAssertEqual(model.selectedID, original[32].id)

        model.records = [record(-1)] + original
        model.isSearching = false
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendant(NSTableView.self, in: host) === table)
        XCTAssertEqual(table.numberOfRows, original.count + 1)
        XCTAssertEqual(table.rect(ofRow: row + 1).minY - scroll.contentView.bounds.minY, before, accuracy: 0.01)
        XCTAssertEqual(model.selectedID, original[32].id)

        if let path = ProcessInfo.processInfo.environment["HISTORY_SCROLL_PREVIEW"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testNewRecordingsPreserveTheExactVisiblePositionAtTopMiddleAndBottom() async throws {
        for position in [CGFloat(0), 19.5, 2_447.5, 100_000] {
            let fixture = HistoryListFixture()
            let original = (0..<100).map { record($0) }
            fixture.update(original, selectedID: original.first?.id)
            fixture.scroll(to: position)
            let anchor = try fixture.anchor()
            let before = fixture.screenY(of: anchor)

            fixture.update([record(-3), record(-2), record(-1)] + original, selectedID: original.first?.id)
            fixture.settleLayout()

            XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
            XCTAssertEqual(fixture.coordinator.tableView.numberOfRows, 103)
            XCTAssertEqual(fixture.selectedID, original.first?.id)
            XCTAssertTrue(fixture.selectionEvents.isEmpty, "A refresh must not change selection")
        }
    }

    func testRepeatedRefreshesAndTranscriptCompletionDoNotMoveTheViewport() async throws {
        let fixture = HistoryListFixture()
        var records = (0..<100).map { record($0, transcript: "", status: "recording") }
        fixture.update(records, selectedID: records[80].id)
        fixture.scroll(to: 2_447.5)
        let anchor = try fixture.anchor()
        let before = fixture.screenY(of: anchor)

        for cycle in 0..<5 {
            fixture.update(records, selectedID: records[80].id)
            records[0] = record(0, transcript: String(repeating: "Completed transcript. ", count: 100))
            records[32] = record(32, transcript: "Visible transcript update \(cycle)")
            fixture.update(records, selectedID: records[80].id)
            fixture.settleLayout()
            XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
        }

        try await Task.sleep(for: .milliseconds(30))
        fixture.settleLayout()
        XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
        XCTAssertEqual(fixture.selectedID, records[80].id)
        XCTAssertTrue(fixture.selectionEvents.isEmpty)
    }

    func testUserScrollingAfterAnInsertionIsNeverUndoneByDeferredLayout() async throws {
        let fixture = HistoryListFixture()
        let original = (0..<100).map { record($0) }
        fixture.update(original)
        fixture.scroll(to: 2_447.5)
        let updated = [record(-1)] + original
        fixture.update(updated)
        fixture.scroll(to: 4_111.5)
        let anchor = try fixture.anchor()
        let before = fixture.screenY(of: anchor)

        try await Task.sleep(for: .milliseconds(30))
        fixture.update(updated)
        fixture.settleLayout()

        XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
    }

    func testOnlyAChangedSearchOrSurfaceFilterResetsThePosition() async throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map { record($0) }
        fixture.update(records, filterKey: "search-a/all")
        fixture.scroll(to: 2_447.5)
        let before = fixture.coordinator.scrollView.contentView.bounds.minY
        fixture.update(records, filterKey: "search-a/all")
        XCTAssertEqual(fixture.coordinator.scrollView.contentView.bounds.minY, before, accuracy: 0.01)

        fixture.update(records, filterKey: "search-b/all")
        XCTAssertEqual(fixture.coordinator.scrollView.contentView.bounds.minY, 0, accuracy: 0.01)
        fixture.scroll(to: 2_447.5)
        fixture.update(records, filterKey: "search-b/composer")
        XCTAssertEqual(fixture.coordinator.scrollView.contentView.bounds.minY, 0, accuracy: 0.01)
    }

    func testAFilteredOutAnchorKeepsTheNextSurvivingVisibleRowInPlace() async throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map { record($0) }
        fixture.update(records)
        fixture.scroll(to: 2_447.5)
        let anchor = try fixture.anchor()
        let index = try XCTUnwrap(records.firstIndex { $0.id == anchor })
        let nextID = records[index + 1].id
        let before = fixture.screenY(of: nextID)

        fixture.update(records.filter { $0.id != anchor })

        XCTAssertEqual(fixture.screenY(of: nextID), before, accuracy: 0.01)
    }

    func testNativeSelectionStillSelectsTheCorrectRecordingAfterInsertion() async throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map { record($0) }
        fixture.update(records, selectedID: records[50].id)
        fixture.update([record(-1)] + records, selectedID: records[50].id)
        XCTAssertEqual(fixture.selectedID, records[50].id)
        XCTAssertTrue(fixture.selectionEvents.isEmpty)

        fixture.coordinator.tableView.selectRowIndexes(IndexSet(integer: 52), byExtendingSelection: false)
        XCTAssertEqual(fixture.selectionEvents, [records[51].id])
    }

    func testRowsKeepTheirHeightWhenThePaneNarrows() async throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map {
            record($0, transcript: String(repeating: "A long transcript with several lines. ", count: 20))
        }
        fixture.update(records)
        fixture.scroll(to: 2_447.5)
        let anchor = try fixture.anchor()
        let before = fixture.screenY(of: anchor)
        for width in [CGFloat(280), 400, 320] {
            fixture.window.setContentSize(NSSize(width: width, height: 330))
            fixture.settleLayout()
            XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
            let row = fixture.coordinator.records.firstIndex { $0.id == anchor }!
            XCTAssertEqual(fixture.coordinator.tableView.rect(ofRow: row).height, 76, accuracy: 0.01)
            let cell = try XCTUnwrap(fixture.coordinator.tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
            XCTAssertLessThanOrEqual(cell.frame.height, 76)
            XCTAssertGreaterThan(cell.frame.width, width - 60)
        }
    }

    func testReturningFromContextRestoresTheReadingPositionAfterNewRecordingsArrive() throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map { record($0) }
        fixture.update(records, selectedID: records[33].id, filterKey: "search/all")
        fixture.scroll(to: 2_447.5)
        let anchor = try fixture.anchor()
        let before = fixture.screenY(of: anchor)

        fixture.coordinator.update(
            records: Array(records[30...36].reversed()), selectedID: records[33].id,
            filterKey: "context:33", positionGroup: "context", rowHeight: 100
        )
        fixture.settleLayout()
        fixture.scroll(to: 190)
        fixture.coordinator.update(
            records: [record(-1)] + records, selectedID: records[33].id,
            filterKey: "search/all", positionGroup: "results"
        )
        fixture.settleLayout()
        XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
        XCTAssertEqual(fixture.selectedID, records[33].id)
        XCTAssertTrue(fixture.selectionEvents.isEmpty)
    }

    func testExplicitRevealCentersTheRecordingOnceAndDoesNotUndoUserScrolling() throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map { record($0) }
        let request = HistoryScrollRequest(recordID: records[80].id)
        fixture.coordinator.update(records: records, selectedID: records[80].id, filterKey: "all", scrollRequest: request)
        fixture.settleLayout()
        XCTAssertTrue(fixture.coordinator.tableView.rows(in: fixture.coordinator.scrollView.contentView.bounds).contains(80))
        fixture.scroll(to: 2_447.5)
        let anchor = try fixture.anchor()
        let before = fixture.screenY(of: anchor)
        fixture.coordinator.update(records: [record(-1)] + records, selectedID: records[80].id, filterKey: "all", scrollRequest: request)
        fixture.settleLayout()
        XCTAssertEqual(fixture.screenY(of: anchor), before, accuracy: 0.01)
    }

    func testRevealWaitsUntilItsTargetIsAvailable() throws {
        let fixture = HistoryListFixture()
        let records = (0..<100).map { record($0) }
        let request = HistoryScrollRequest(recordID: records[80].id)
        fixture.coordinator.update(records: Array(records.prefix(3)), selectedID: nil, filterKey: "all", scrollRequest: request)
        fixture.coordinator.update(records: records, selectedID: records[80].id, filterKey: "all", scrollRequest: request)
        fixture.settleLayout()
        XCTAssertTrue(fixture.coordinator.tableView.rows(in: fixture.coordinator.scrollView.contentView.bounds).contains(80))
    }

    private func record(_ index: Int, transcript: String = "Synthetic recording", status: String = "completed") -> ArchivedDictationRecord {
        let date = Date(timeIntervalSince1970: 1_788_000_000 - Double(index))
        return ArchivedDictationRecord(
            id: "record-\(index)", sourceKey: "source-\(index)", createdAt: date,
            durationSeconds: 12, status: status, surface: .composer, transcript: transcript,
            mimeType: "audio/webm", audioSizeBytes: 0, expectedSizeBytes: nil,
            archiveFolderURL: URL(fileURLWithPath: "/unused-history-scroll-fixture/\(index)"),
            audioSHA256: nil, metadataSHA256: nil, isPartial: status != "completed",
            firstCapturedAt: date, updatedAt: date
        )
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

@MainActor
private final class HistoryResultsFixtureModel: ObservableObject {
    @Published var records: [ArchivedDictationRecord]
    @Published var selectedID: String?
    @Published var isSearching = false

    init(records: [ArchivedDictationRecord]) {
        self.records = records
        selectedID = records[32].id
    }
}

private struct HistoryResultsFixtureView: View {
    @ObservedObject var model: HistoryResultsFixtureModel

    var body: some View {
        HistoryResultsView(
            records: model.records, selectedID: $model.selectedID,
            filterKey: "synthetic/all", isSearching: model.isSearching, archiveIsEmpty: false
        ) { _ in
            XCTFail("A presentation refresh must never invoke deletion")
        }
    }
}

@MainActor
private final class HistoryListFixture {
    let coordinator = AnchoredHistoryList<RecordingListRow>.Coordinator { RecordingListRow(record: $0) }
    let window: NSWindow
    var selectionEvents: [String?] = []

    init() {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 330),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = coordinator.scrollView
        coordinator.onSelection = { [weak self] in self?.selectionEvents.append($0) }
        settleLayout()
    }

    var selectedID: String? {
        let row = coordinator.tableView.selectedRow
        return coordinator.records.indices.contains(row) ? coordinator.records[row].id : nil
    }

    func update(_ records: [ArchivedDictationRecord], selectedID: String? = nil, filterKey: String = "all") {
        coordinator.update(records: records, selectedID: selectedID, filterKey: filterKey)
        settleLayout()
    }

    func settleLayout() {
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.tableView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func scroll(to y: CGFloat) {
        let clip = coordinator.scrollView.contentView
        let maxY = max(0, coordinator.tableView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(maxY, y)))
        coordinator.scrollView.reflectScrolledClipView(clip)
        settleLayout()
    }

    func anchor() throws -> String {
        let range = coordinator.tableView.rows(in: coordinator.scrollView.contentView.bounds)
        XCTAssertGreaterThan(range.length, 0)
        return try XCTUnwrap(coordinator.records.indices.contains(range.location) ? coordinator.records[range.location].id : nil)
    }

    func screenY(of id: String) -> CGFloat {
        guard let row = coordinator.records.firstIndex(where: { $0.id == id }) else { return .nan }
        return coordinator.tableView.rect(ofRow: row).minY - coordinator.scrollView.contentView.bounds.minY
    }
}
