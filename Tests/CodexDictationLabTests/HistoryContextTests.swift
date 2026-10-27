import AppKit
import DictationArchiveCore
import SwiftUI
import XCTest
@testable import CodexDictationLab

@MainActor
final class HistoryContextTests: XCTestCase {
    func testContextIncludesBothSourcesAndEmptyPartialRecordingsInTimeOrder() throws {
        let records = (0..<20).reversed().map { contextRecord($0) }
        let anchor = try XCTUnwrap(records.first { $0.id == "record-8" })
        let window = RecordingContext(anchor: anchor).window(in: records)
        XCTAssertEqual(window.records.map(\.id), (5...11).map { "record-\($0)" })
        XCTAssertEqual(anchor.surface, .global)
        XCTAssertEqual(window.records.first?.surface, .composer)
        XCTAssertEqual(window.records.first { $0.id == "record-9" }?.transcript, "")
        XCTAssertTrue(window.records.first { $0.id == "record-9" }?.isPartial == true)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
    }

    func testContextExpansionBoundariesAndLiveInsertionsKeepTheOriginalAnchor() throws {
        let records = (0..<20).reversed().map { contextRecord($0) }
        let anchor = try XCTUnwrap(records.first { $0.id == "record-8" })
        let model = HistoryNavigationModel()
        model.showContext(around: anchor)
        model.showMoreEarlier()
        model.showMoreLater()
        let context = try XCTUnwrap(model.context)
        XCTAssertEqual(context.window(in: records).records.map(\.id), (2...14).map { "record-\($0)" })
        XCTAssertEqual(context.window(in: [contextRecord(20)] + records).records.map(\.id), (2...14).map { "record-\($0)" })
        XCTAssertEqual(model.returnToResults(), anchor.id)
        XCTAssertNil(model.context)

        let start = RecordingContext(anchor: contextRecord(0)).window(in: records)
        XCTAssertFalse(start.hasEarlier)
        XCTAssertTrue(start.hasLater)
        let end = RecordingContext(anchor: contextRecord(19)).window(in: records)
        XCTAssertTrue(end.hasEarlier)
        XCTAssertFalse(end.hasLater)
        XCTAssertTrue(RecordingContext(anchor: contextRecord(99)).window(in: records).records.isEmpty)
    }

    func testDeletedRecordingsAreExcludedAndTimestampTiesUseTheArchiveOrder() {
        let original = contextRecord(8)
        let tied = contextRecord(7, date: original.createdAt)
        let deleted = contextRecord(6, deleted: true)
        let records = [contextRecord(9), tied, original, deleted, contextRecord(5)]
        let window = RecordingContext(anchor: original).window(in: records)
        XCTAssertEqual(window.records.map(\.id), ["record-5", "record-8", "record-7", "record-9"])
        XCTAssertFalse(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
        XCTAssertEqual(RecordingContext.relativeTime(tied.createdAt, to: original.createdAt), "Same time")
        XCTAssertTrue(RecordingContext.relativeTime(contextRecord(5).createdAt, to: original.createdAt).hasSuffix("earlier"))
        XCTAssertTrue(RecordingContext.relativeTime(contextRecord(100_000).createdAt, to: original.createdAt).hasSuffix("later"))
    }

    func testContextReturnsToTheExactSearchPositionAndFullHistoryRevealsTheSelection() async throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ArchiveStore(layout: fixture.layout)
        for index in 0..<100 {
            try store.upsert(contextRecord(index, folder: fixture.root))
        }
        let state = AppState(layout: fixture.layout, sourceURL: fixture.root.appendingPathComponent("Source"))
        await state.refreshArchive()
        let navigation = HistoryNavigationModel()
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HistoryView(navigation: navigation).environmentObject(state).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_050, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await waitUntil("initial history", in: host) { self.table(in: host)?.numberOfRows == 100 }
        let field = try XCTUnwrap(searchField(in: host))
        field.stringValue = "Synthetic"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await waitUntil("search results", in: host) { self.table(in: host)?.numberOfRows == 99 }
        navigation.surfaceFilter = .composer
        try await waitUntil("filtered search results", in: host) { self.table(in: host)?.numberOfRows == 98 }
        let table = try XCTUnwrap(table(in: host))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2_447.5))
        scroll.reflectScrolledClipView(scroll.contentView)
        let originalRow = table.rows(in: scroll.contentView.bounds).location
        table.selectRowIndexes(IndexSet(integer: originalRow + 1), byExtendingSelection: false)
        let originalID = try XCTUnwrap(state.selectedRecordID)
        let originalY = scroll.contentView.bounds.minY

        if let path = ProcessInfo.processInfo.environment["HISTORY_CONTEXT_PREVIEW"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + ".initial.png"))
        }

        navigation.showContext(around: try XCTUnwrap(state.records.first { $0.id == originalID }))
        try await waitUntil("initial context", in: host) { table.numberOfRows == 7 }
        XCTAssertTrue(self.table(in: host) === table, "Keep the same list mounted across modes")
        XCTAssertEqual(navigation.context?.anchor.id, originalID)
        XCTAssertNil(searchField(in: host))
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        XCTAssertNotEqual(state.selectedRecordID, originalID)
        XCTAssertEqual(navigation.context?.anchor.id, originalID)
        navigation.showMoreEarlier()
        try await waitUntil("more earlier", in: host) { table.numberOfRows == 10 }
        navigation.showMoreLater()
        try await waitUntil("more later", in: host) { table.numberOfRows == 13 }

        if let path = ProcessInfo.processInfo.environment["HISTORY_CONTEXT_PREVIEW"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }

        navigation.returnToResults()
        try await waitUntil("return to search", in: host) { table.numberOfRows == 98 && self.searchField(in: host) != nil }
        XCTAssertEqual(searchField(in: host)?.stringValue, "Synthetic")
        XCTAssertEqual(navigation.surfaceFilter, .composer)
        XCTAssertEqual(state.selectedRecordID, originalID)
        XCTAssertEqual(scroll.contentView.bounds.minY, originalY, accuracy: 0.01)

        navigation.showContext(around: try XCTUnwrap(state.records.first { $0.id == originalID }))
        try await waitUntil("reopened context", in: host) { table.numberOfRows == 7 }
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let neighborID = state.selectedRecordID
        navigation.showFullHistory(try XCTUnwrap(neighborID))
        try await waitUntil("full history", in: host) { table.numberOfRows == 100 && self.searchField(in: host) != nil }
        XCTAssertEqual(searchField(in: host)?.stringValue, "")
        XCTAssertEqual(navigation.surfaceFilter, .all)
        XCTAssertEqual(state.selectedRecordID, neighborID)
        XCTAssertTrue(table.rows(in: scroll.contentView.bounds).contains(table.selectedRow))
        XCTAssertNil(navigation.context)

        navigation.surfaceFilter = .global
        try await waitUntil("global filter", in: host) { table.numberOfRows == 1 }
        let global = try XCTUnwrap(state.records.first { $0.id == "record-8" })
        navigation.showContext(around: global)
        try await waitUntil("cross-source context", in: host) { table.numberOfRows == 7 }
        XCTAssertEqual(navigation.context?.window(in: state.records).records.map(\.id), (5...11).map { "record-\($0)" })
        navigation.returnToResults()
        try await waitUntil("restored global filter", in: host) { table.numberOfRows == 1 }
        XCTAssertEqual(navigation.surfaceFilter, .global)
        XCTAssertEqual(state.selectedRecordID, global.id)

        navigation.showContext(around: global)
        try await waitUntil("context before deletion", in: host) { table.numberOfRows == 7 }
        try store.softDelete(id: global.id)
        await state.refreshArchive()
        try await waitUntil("deleted original leaves context safely", in: host) { table.numberOfRows == 0 && navigation.context == nil }
        XCTAssertNil(state.selectedRecordID)
    }

    private func table(in host: NSView) -> NSTableView? { descendants(NSTableView.self, in: host).first }
    private func searchField(in host: NSView) -> NSTextField? {
        descendants(NSTextField.self, in: host).first { $0.isEditable && $0.placeholderString == "Search exact transcripts" }
    }
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func waitUntil(_ description: String, in host: NSView, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("History context did not reach \(description); rows=\(table(in: host)?.numberOfRows ?? -1)", file: file, line: line)
        throw NSError(domain: "HistoryContextTests", code: 1)
    }
}

private func contextRecord(_ index: Int, date: Date? = nil, deleted: Bool = false, folder: URL = URL(fileURLWithPath: "/unused-history-context-fixture")) -> ArchivedDictationRecord {
    let date = date ?? Date(timeIntervalSince1970: 1_788_000_000 + Double(index) * 60)
    return ArchivedDictationRecord(
        id: "record-\(index)", sourceKey: "source-\(index)", createdAt: date,
        durationSeconds: 7, status: index == 9 ? "cancelled" : "completed",
        surface: index == 8 ? .global : .composer, transcript: index == 9 ? "" : "Synthetic transcript \(index)",
        mimeType: "audio/webm", audioSizeBytes: 0, expectedSizeBytes: nil,
        archiveFolderURL: folder, audioSHA256: nil, metadataSHA256: nil,
        isPartial: index == 9, isDeleted: deleted, firstCapturedAt: date, updatedAt: date
    )
}
