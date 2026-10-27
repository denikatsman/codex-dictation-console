import AppKit
import DictationArchiveCore
import SwiftUI
import XCTest
@testable import CodexDictationLab

@MainActor
final class HistorySearchTests: XCTestCase {
    func testVisibleHistorySearchTypesChangesAndClearsAgainstSyntheticArchive() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (id, transcript) in [
            ("meeting", "Café meeting notes"),
            ("recipe", "Café recipe notes"),
            ("agenda", "Weekly agenda")
        ] {
            _ = try fixture.makeSourceRecording(
                sourceKey: id, id: id, transcript: transcript, chunks: []
            )
        }
        _ = try fixture.engine.scan()
        let state = AppState(layout: fixture.layout, sourceURL: fixture.source)
        await state.refreshArchive()
        XCTAssertEqual(state.records.count, 3)
        state.section = .history

        _ = NSApplication.shared
        let host = NSHostingView(rootView: ContentView().environmentObject(state))
        let window = makeHiddenWindow(host: host)
        defer { window.close() }
        try await waitUntil("initial three history rows", in: host) { self.historyTable(in: host)?.numberOfRows == 3 }
        let field = try XCTUnwrap(searchField(in: host), "Search must exist inside the actual nested History layout")
        assertVisible(field, in: host)

        enter("café", into: field)
        try await waitUntil("café matches two records", in: host) { self.historyTable(in: host)?.numberOfRows == 2 }
        enter("café meeting", into: field)
        try await waitUntil("café meeting matches one record", in: host) { self.historyTable(in: host)?.numberOfRows == 1 }
        enter("missing words", into: field)
        try await waitUntil("missing words has no matches", in: host) { self.historyTable(in: host)?.numberOfRows == 0 }
        enter("weekly", into: field)
        try await waitUntil("weekly replaces the prior match", in: host) { self.historyTable(in: host)?.numberOfRows == 1 }
        enter("", into: field)
        try await waitUntil("clearing restores all three records", in: host) { self.historyTable(in: host)?.numberOfRows == 3 }
        XCTAssertNil(state.alertMessage)

        state.section = .overview
        try await waitUntil("navigation leaves History", in: host) { self.searchField(in: host) == nil }
        state.section = .history
        try await waitUntil("navigation restores search", in: host) { self.searchField(in: host) != nil }
        assertVisible(try XCTUnwrap(searchField(in: host)), in: host)

        // Recreate the window without displaying it or operating the desktop.
        let reopenedHost = NSHostingView(rootView: ContentView().environmentObject(state))
        let reopenedWindow = makeHiddenWindow(host: reopenedHost)
        defer { reopenedWindow.close() }
        try await waitUntil("recreated window contains search", in: reopenedHost) { self.searchField(in: reopenedHost) != nil }
        assertVisible(try XCTUnwrap(searchField(in: reopenedHost)), in: reopenedHost)
    }

    private func makeHiddenWindow<Content: View>(host: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_050, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func searchField(in view: NSView) -> NSTextField? {
        descendants(NSTextField.self, in: view).first {
            $0.isEditable && $0.placeholderString == "Search exact transcripts"
        }
    }

    private func historyTable(in view: NSView) -> NSTableView? {
        descendants(NSTableView.self, in: view).first {
            $0.tableColumns.first?.identifier.rawValue == "recording"
        }
    }

    private func enter(_ text: String, into field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func assertVisible(_ field: NSTextField, in host: NSView, file: StaticString = #filePath, line: UInt = #line) {
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertGreaterThan(field.bounds.width, 100, file: file, line: line)
        XCTAssertGreaterThan(field.bounds.height, 10, file: file, line: line)
        XCTAssertTrue(host.bounds.contains(field.convert(field.bounds, to: host)), file: file, line: line)
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
        let fields = descendants(NSTextField.self, in: host).map { "\(type(of: $0)): editable=\($0.isEditable), placeholder=\($0.placeholderString ?? "nil")" }
        XCTFail("Timed out waiting for \(description). Row count: \(String(describing: historyTable(in: host)?.numberOfRows)); fields: \(fields)", file: file, line: line)
        throw NSError(domain: "HistorySearchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
