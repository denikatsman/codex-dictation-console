import AppKit
import SwiftUI
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

@MainActor
final class DictationStatusCardTests: XCTestCase {
    func testSummaryUsesTheExistingArchiveStateAndSelection() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "local.codex-dictation-tests.card.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(layout: fixture.layout, sourceURL: fixture.source,
                             accessSettings: AppAccessSettings(defaults: defaults))
        XCTAssertEqual(DictationCardSummary(state: state).status, "Loading the library…")
        _ = try fixture.makeSourceRecording(sourceKey: "card", id: "recent", transcript: "Private words", chunks: [Data("audio".utf8)])
        _ = try fixture.engine.scan()
        await state.refreshArchive()
        let summary = DictationCardSummary(state: state)
        XCTAssertEqual(summary.recordingCount, 1)
        XCTAssertEqual(summary.latestRecordID, "recent")
        XCTAssertEqual(summary.lastArchived, state.captureHealth?.lastCaptureAt ?? state.records.first?.firstCapturedAt)
        XCTAssertFalse(summary.status.contains("Private words"))
        state.showRecording(id: try XCTUnwrap(summary.latestRecordID))
        XCTAssertEqual(state.selectedRecordID, "recent")
        XCTAssertEqual(state.section, .history)
        // Card reads do not create another scan or mutate capture settings.
        let before = try Data(contentsOf: fixture.layout.statusURL)
        for _ in 0..<100 { _ = DictationCardSummary(state: state) }
        XCTAssertEqual(try Data(contentsOf: fixture.layout.statusURL), before)
        let stale = DictationCardSummary(state: state, now: Date().addingTimeInterval(3600))
        XCTAssertTrue(stale.warning?.contains("stale") == true)
    }

    func testOffscreenCardsKeepActionsStableAcrossStatesAndAppearances() throws {
        let now = Date(timeIntervalSince1970: 1790953200)
        let variants: [(String, DictationCardSummary)] = [
            ("empty", .init(status: "Capture is off", symbol: "pause.circle")),
            ("loading", .init(status: "Loading the library…", symbol: "clock")),
            ("running", .init(status: "Capture helper is running", recordingCount: 4625,
                               lastArchived: now, lastScan: now, latestRecordID: "fixture")),
            ("stale", .init(status: "Capture helper is running", warning: "Capture status is stale. The last scan does not confirm current protection.", recordingCount: 4625)),
            ("error", .init(status: "Capture helper is not running", symbol: "exclamationmark.circle",
                             warning: "Codex history is unavailable. Check source access in Diagnostics.")),
            ("long", .init(status: "A long capture status that needs two lines in this compact library card",
                            warning: "This longer diagnostic preview explains that the last known scan is unavailable and gives an accessible route to the full information in the library."))
        ]
        var heights: [CGFloat] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let dark = appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua
            for (name, summary) in variants {
                let card = DictationStatusCardContent(summary: summary, open: {}, settings: {}, latest: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.sizeCategory, .extraExtraExtraLarge)
                let host = NSHostingView(rootView: card)
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                XCTAssertEqual(size.width, 360, accuracy: 1)
                XCTAssertGreaterThan(size.height, 250)
                XCTAssertLessThan(size.height, 450)
                heights.append(size.height)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                if let directory = ProcessInfo.processInfo.environment["CDL_CARD_RENDER_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: url.appendingPathComponent("\(name)-\(appearance.rawValue).png"))
                }
            }
        }
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 2,
                                "Status changes must not shift actions under the pointer")
    }
}
