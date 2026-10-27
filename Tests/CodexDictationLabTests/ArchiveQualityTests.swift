import Foundation
import SQLite3
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

final class ArchiveQualityTests: XCTestCase {
    func testNewerArchiveSchemaIsRefusedWithoutDowngradingIt() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.layout.databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 99; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES ('preserved');", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try fixture.store.prepare()) { error in
            XCTAssertTrue(error.localizedDescription.contains("schema version 99"))
        }
        var version: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &version, nil), SQLITE_OK)
        defer { sqlite3_finalize(version) }
        XCTAssertEqual(sqlite3_step(version), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(version, 0), 99)
        var row: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT value FROM future_data;", -1, &row, nil), SQLITE_OK)
        defer { sqlite3_finalize(row) }
        XCTAssertEqual(sqlite3_step(row), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(row, 0))), "preserved")
    }

    func testCorruptManifestSizesAreReportedWithoutOverflowOrCancellation() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "one"))
        let original = try Data(contentsOf: record.manifestURL)
        for sizes: [Int64] in [[.max, 1], [-1, 6]] {
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            manifest["chunks"] = sizes.enumerated().map { index, size in
                ["filename": "\(index).chunk", "index": index, "sizeBytes": size, "sha256": "fixture"] as [String: Any]
            }
            try JSONSerialization.data(withJSONObject: manifest).write(to: record.manifestURL, options: .atomic)
            let result = try fixture.store.verifyArchivedFiles()
            XCTAssertTrue(result.issues.contains { $0.message.contains("chunk sizes") })
            XCTAssertThrowsError(try fixture.store.audioManifest(for: record))
            XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("audio".utf8))
        }
    }

    func testCorruptMetadataHistoryStopsExportAndLeavesNoIncompletePackage() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words", chunks: [Data("audio".utf8)])
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "one"))
        let history = record.archiveFolderURL.appendingPathComponent("Metadata History")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let original = try Data(contentsOf: record.metadataURL)
        let snapshot = history.appendingPathComponent(DictationCaptureEngine.sha256(original) + ".json")
        try Data("damaged history".utf8).write(to: snapshot)
        let destination = fixture.root.appendingPathComponent("Export")
        let exporter = ArchiveExporter(store: fixture.store)
        XCTAssertThrowsError(try exporter.export(recordID: record.id, to: destination))
        XCTAssertThrowsError(try exporter.exportAll(to: destination))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: snapshot), Data("damaged history".utf8))

        try original.write(to: snapshot)
        let exported = try exporter.export(recordID: record.id, to: destination)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("Metadata History").appendingPathComponent(snapshot.lastPathComponent)), original)
    }

    func testUnrelatedAccountBucketIsNotPresentedAsCodexUsage() {
        let bucket = MeterBucketSnapshot(id: "other-product", name: "Other", primary: nil, secondary: nil)
        let snapshot = AccountUsageSnapshot(planType: nil, buckets: [bucket], lifetimeTokens: nil, latestDailyTokens: nil)
        XCTAssertNil(snapshot.codexBucket)
    }

    func testInvalidAccountNumbersRemainUnavailable() throws {
        for value: Any in [true, -1, Double(Int.max), Double.infinity, Double.nan] {
            XCTAssertNil(AppServerProbeSession.parseWindow(["usedPercent": value])?.usedPercent)
        }
        for value: Any in [true, 0, -1, 1.5, Double.infinity] {
            XCTAssertNil(AppServerProbeSession.parseWindow(["windowDurationMins": value])?.windowDurationMinutes)
        }
        for value: Any in [true, -1, Double.infinity, Double.nan] {
            XCTAssertNil(AppServerProbeSession.parseWindow(["resetsAt": value])?.resetsAt)
        }
        let valid = try XCTUnwrap(AppServerProbeSession.parseWindow(["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1234]))
        XCTAssertEqual(valid.usedPercent, 100)
        XCTAssertEqual(valid.windowDurationMinutes, 300)
        XCTAssertEqual(valid.resetsAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(AppServerProbeSession.parseWindow(["usedPercent": 101])?.usedPercent, 101)
    }
}
