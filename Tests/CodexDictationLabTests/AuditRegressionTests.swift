import Foundation
import SQLite3
import XCTest
@testable import DictationArchiveCore
@testable import CodexDictationLab

// Synthetic versions of the preserved audit fixtures. Assertions describe the
// corrected behavior, not the original audits' defect assertions.
final class AuditRegressionTests: XCTestCase {
    func testCDL005VersionOneMigrationPreservesRecordsAndDoesNotCertifyOldTombstones() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Preserve history", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        try f.store.softDelete(id: "one")
        let before = try XCTUnwrap(f.store.record(id: "one"))
        // Recreate exactly the previous tombstone schema over existing rows.
        try sql(f, "ALTER TABLE tombstones DROP COLUMN cleanup_complete; PRAGMA user_version = 1;")
        try f.store.prepare()
        XCTAssertEqual(try f.store.record(id: "one"), before)
        XCTAssertTrue(try f.store.isTombstoned(sourceKey: "source"))
        XCTAssertEqual(try Data(contentsOf: before.audioURL), Data("audio".utf8))
        // An old tombstone without a row must not turn into certified success.
        try sql(f, "DELETE FROM records WHERE id = 'one';")
        XCTAssertThrowsError(try f.store.permanentlyDelete(id: "one"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.audioURL.path))
    }

    func testCDL001PreservationStillAllowsVerifiedCompleteAudioExtension() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "First", chunks: [Data("FIRST".utf8)])
        _ = try f.engine.scan()
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Longer", chunks: [Data("FIRST".utf8), Data("SECOND".utf8)])
        XCTAssertTrue(try f.engine.scan().errors.isEmpty)
        let record = try XCTUnwrap(f.store.record(id: "one"))
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("FIRSTSECOND".utf8))
        XCTAssertFalse(record.isPartial)
        XCTAssertTrue(try f.store.verifyArchivedFiles().isHealthy)
    }

    func testCDL001CompleteAudioSurvivesEmptyTranscriptCleanupAndIncompatibleMetadata() throws {
        for text in ["", "  \n"] {
            let f = try CaptureFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: text,
                chunks: [Data("FIRST".utf8), Data("SECOND".utf8)])
            _ = try f.engine.scan()
            let before = try XCTUnwrap(f.store.record(id: "one"))
            try FileManager.default.removeItem(at: source.appendingPathComponent("0000000000.chunk"))
            try FileManager.default.removeItem(at: source.appendingPathComponent("metadata.json"))
            _ = try f.engine.scan()
            try FileManager.default.removeItem(at: source)
            _ = try f.engine.scan()
            XCTAssertEqual(try Data(contentsOf: before.audioURL), Data("FIRSTSECOND".utf8))
            XCTAssertEqual(try f.store.record(id: "one")?.audioSizeBytes, 11)
            XCTAssertFalse(try XCTUnwrap(f.store.record(id: "one")).isPartial)
            _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Later words",
                chunks: [Data("FIRST".utf8)], expectedSize: 11, status: "future-status")
            XCTAssertFalse(try f.engine.scan().errors.isEmpty)
            XCTAssertEqual(try Data(contentsOf: before.audioURL), Data("FIRSTSECOND".utf8))
            XCTAssertEqual(try f.store.record(id: "one")?.transcript, "Later words")
        }
    }

    func testCDL002CorruptStagingCannotReplaceKnownPartialAudioAndValidGrowthStillWorks() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words",
            chunks: [Data("FIRST".utf8)], expectedSize: 11)
        _ = try f.engine.scan()
        let original = try XCTUnwrap(f.store.record(id: "one"))
        let stage = staging(f, "source")
        try Data("FAULT".utf8).write(to: stage.appendingPathComponent("Chunks/0000000000.chunk"))
        try FileManager.default.removeItem(at: source)
        XCTAssertFalse(try f.engine.scan().errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original.audioURL), Data("FIRST".utf8))
        XCTAssertEqual(try f.store.record(id: "one")?.audioSHA256, original.audioSHA256)
        XCTAssertTrue(try f.store.verifyArchivedFiles().isHealthy)
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Saved words",
            chunks: [Data("FIRST".utf8), Data("SECOND".utf8)])
        XCTAssertTrue(try f.engine.scan().errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original.audioURL), Data("FIRSTSECOND".utf8))
        XCTAssertFalse(try XCTUnwrap(f.store.record(id: "one")).isPartial)
    }

    func testCDL003BlankAndReusedIDsNeverOverwriteAnotherSource() throws {
        for metadataID in ["", "shared"] {
            let f = try CaptureFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            for (key, text) in [("a", "first"), ("b", "second")] {
                _ = try f.makeSourceRecording(sourceKey: key, id: metadataID, transcript: text, chunks: [Data(text.utf8)])
            }
            _ = try f.engine.scan()
            let records = try f.store.records()
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(Set(records.map(\.id)).count, 2)
            for record in records {
                XCTAssertFalse(record.id.isEmpty)
                XCTAssertEqual(try Data(contentsOf: record.audioURL), Data(record.transcript.utf8))
            }
            let again = try f.engine.scan()
            XCTAssertEqual(again.importedCount + again.updatedCount, 0)
            XCTAssertEqual(try f.store.records(), records)
        }
    }

    func testCDL004SoftDeleteKeepsChunksNeededByRestore() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words",
            chunks: [Data("FIRST".utf8)], expectedSize: 11)
        _ = try f.engine.scan()
        try f.store.softDelete(id: "one")
        try FileManager.default.removeItem(at: source)
        _ = try f.engine.scan()
        XCTAssertEqual(try Data(contentsOf: staging(f, "source").appendingPathComponent("Chunks/0000000000.chunk")), Data("FIRST".utf8))
        try f.store.restore(id: "one")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try f.writeMetadata(to: source, id: "one", transcript: "Words", size: 11)
        try Data("SECOND".utf8).write(to: source.appendingPathComponent("0000000001.chunk"))
        XCTAssertTrue(try f.engine.scan().errors.isEmpty)
        let record = try XCTUnwrap(f.store.record(id: "one"))
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("FIRSTSECOND".utf8))
        XCTAssertFalse(record.isPartial)
    }

    func testCDL005006DeletionRetriesAfterFileCleanupAndDatabaseFailure() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Private words",
            chunks: [Data("FIRST".utf8)], expectedSize: 11)
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        try sql(f, "CREATE TRIGGER reject_delete BEFORE DELETE ON records BEGIN SELECT RAISE(FAIL, 'fixture'); END;")
        XCTAssertThrowsError(try f.store.permanentlyDelete(id: "one"))
        XCTAssertTrue(try f.store.isTombstoned(sourceKey: "source"))
        XCTAssertThrowsError(try f.store.restore(id: "one"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.archiveFolderURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging(f, "source").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.layout.deletionStagingURL.path).contains { $0.hasSuffix(".delete.json") })
        try sql(f, "DROP TRIGGER reject_delete;")
        // A new store/scanner resumes from the durable journal even though the
        // recording files are already absent. Repeating deletion is harmless.
        _ = try f.engine.scan()
        try f.store.permanentlyDelete(id: "one")
        XCTAssertNil(try f.store.record(id: "one"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.layout.deletionStagingURL.path).isEmpty)
        XCTAssertTrue(try f.engine.scan().skippedTombstoneCount > 0)
    }

    func testCDL005CleanupFailureRemainsPendingAndTombstoneAloneIsNotSuccess() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Private", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        XCTAssertEqual(chflags(record.audioURL.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(record.audioURL.path, 0) }
        XCTAssertThrowsError(try f.store.permanentlyDelete(id: "one"))
        let journalName = DictationCaptureEngine.sha256(Data("one".utf8)) + ".delete.json"
        let moved = f.layout.deletionStagingURL.appendingPathComponent(journalName + ".pending/0/audio.webm")
        defer { _ = chflags(moved.path, 0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertNotNil(try f.store.record(id: "one"))
        XCTAssertThrowsError(try f.store.permanentlyDelete(id: "one"))
        XCTAssertEqual(chflags(moved.path, 0), 0)
        try f.store.permanentlyDelete(id: "one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertNil(try f.store.record(id: "one"))
    }

    func testCDL007TombstonedLogicalIDCannotReimportFromAnotherSourceFolder() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "a", id: "shared", transcript: "Private", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        try f.store.permanentlyDelete(id: "shared")
        _ = try f.makeSourceRecording(sourceKey: "alias", id: "shared", transcript: "Private", chunks: [Data("audio".utf8)])
        XCTAssertEqual(try f.engine.scan().skippedTombstoneCount, 2)
        XCTAssertTrue(try f.store.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging(f, "alias").path))
    }

    func testCDL005JournalBeforeFirstMoveResumesButUnjournaledMaterialIsPreserved() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        let journal: [String: Any] = ["version": 1, "id": "one", "sourceKey": "source",
            "recordingFolder": record.archiveFolderURL.lastPathComponent, "requestedAt": "2026-09-19T00:00:00Z"]
        let name = DictationCaptureEngine.sha256(Data("one".utf8)) + ".delete.json"
        try JSONSerialization.data(withJSONObject: journal).write(to: f.layout.deletionStagingURL.appendingPathComponent(name))
        let legacy = f.layout.deletionStagingURL.appendingPathComponent("old-unjournaled-folder")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("ambiguous historical audio".utf8).write(to: legacy.appendingPathComponent("audio.webm"))
        let result = try f.engine.scan()
        XCTAssertNil(try f.store.record(id: "one"), result.errors.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.archiveFolderURL.path))
        XCTAssertTrue(result.errors.contains { $0.contains("Unjournaled") })
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("audio.webm")), Data("ambiguous historical audio".utf8))
    }

    func testCDL008MetadataRetryAfterSourceLossRetainsAudioDescriptor() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "First", chunks: [Data("FIRSTSECOND".utf8)])
        _ = try f.engine.scan()
        let original = try XCTUnwrap(f.store.record(id: "one"))
        try f.writeMetadata(to: source, id: "one", transcript: "Second", size: 11)
        try sql(f, "CREATE TRIGGER reject_upsert BEFORE INSERT ON records BEGIN SELECT RAISE(FAIL, 'fixture'); END;")
        XCTAssertFalse(try f.engine.scan().errors.isEmpty)
        try FileManager.default.removeItem(at: source)
        try sql(f, "DROP TRIGGER reject_upsert;")
        XCTAssertTrue(try f.engine.scan().errors.isEmpty)
        let updated = try XCTUnwrap(f.store.record(id: "one"))
        XCTAssertEqual(updated.transcript, "Second")
        XCTAssertEqual(updated.audioSizeBytes, 11)
        XCTAssertEqual(updated.audioSHA256, original.audioSHA256)
        XCTAssertFalse(updated.isPartial)
        XCTAssertTrue(try f.store.verifyArchivedFiles().isHealthy)
    }

    func testCDL009HistoryOnlyDurablePrefixPublishesTextWithoutDiscardingAmbiguity() throws {
        for ambiguous in [false, true] {
            let f = try CaptureFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Recover these words", chunks: [])
            let metadata = try Data(contentsOf: source.appendingPathComponent("metadata.json"))
            let stage = staging(f, "source")
            let history = stage.appendingPathComponent("Metadata History")
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data(#"{"sourceKey":"source"}"#.utf8).write(to: stage.appendingPathComponent("source.json"))
            try metadata.write(to: history.appendingPathComponent(DictationCaptureEngine.sha256(metadata) + ".json"))
            if ambiguous {
                let other = Data(#"{"text":"Another version"}"#.utf8)
                try other.write(to: history.appendingPathComponent(DictationCaptureEngine.sha256(other) + ".json"))
            }
            try FileManager.default.removeItem(at: source)
            let scan = try f.engine.scan()
            if ambiguous {
                XCTAssertFalse(scan.errors.isEmpty)
                XCTAssertTrue(try f.store.records().isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 2)
            } else {
                XCTAssertTrue(scan.errors.isEmpty)
                XCTAssertEqual(try f.store.records(search: "Recover").first?.transcript, "Recover these words")
                XCTAssertTrue(try XCTUnwrap(f.store.record(id: "one")).isPartial)
            }
        }
    }

    func testCDL010MissingIndexNeverBecomesHealthyEmptyArchive() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        for suffix in ["", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: f.layout.databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        XCTAssertThrowsError(try f.store.records())
        XCTAssertThrowsError(try f.store.verifyArchivedFiles())
        XCTAssertThrowsError(try ArchiveExporter(store: f.store).exportAll(to: f.root.appendingPathComponent("Export")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.layout.databaseURL.path))
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("audio".utf8))
    }

    func testCDL011RequiredExportFilesCannotBeSilentlySkipped() throws {
        for name in ["audio.webm", "metadata.json", "manifest.json"] {
            let f = try CaptureFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
            _ = try f.engine.scan()
            let record = try XCTUnwrap(f.store.record(id: "one"))
            try FileManager.default.removeItem(at: record.archiveFolderURL.appendingPathComponent(name))
            let exporter = ArchiveExporter(store: f.store)
            let destination = f.root.appendingPathComponent("Exports")
            XCTAssertThrowsError(try exporter.export(recordID: "one", to: destination))
            XCTAssertThrowsError(try exporter.exportAll(to: destination))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    func testCDL012MissingManifestBlocksEvenUnchangedMetadataAndRetriesWhenRestored() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "First", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        let record = try XCTUnwrap(f.store.record(id: "one"))
        let manifest = try Data(contentsOf: record.manifestURL)
        try FileManager.default.removeItem(at: record.manifestURL)
        XCTAssertFalse(try f.engine.scan().errors.isEmpty)
        try f.writeMetadata(to: source, id: "one", transcript: "Second", size: 5)
        XCTAssertFalse(try f.engine.scan().errors.isEmpty)
        XCTAssertEqual(try f.store.record(id: "one")?.transcript, "First")
        try manifest.write(to: record.manifestURL)
        XCTAssertTrue(try f.engine.scan().errors.isEmpty)
        XCTAssertEqual(try f.store.record(id: "one")?.transcript, "Second")
        XCTAssertTrue(try f.store.verifyArchivedFiles().isHealthy)
    }

    func testCDL013DurationBoundaryAndOverflowAreUnavailableWithoutTrapping() throws {
        for value in [1e19, Double(Int.max), Double.infinity, Double.nan, -1] {
            XCTAssertEqual(LabFormatting.duration(value), "Unavailable")
            XCTAssertTrue(ArchiveDuration.total([1, value]).isNaN)
        }
        XCTAssertEqual(LabFormatting.duration(0), "0 sec")
        XCTAssertEqual(LabFormatting.duration(61), "1m 1s")
        XCTAssertTrue(ArchiveDuration.total([Double(Int.max) / 2, Double(Int.max) / 2]).isNaN)
        let metadata = try JSONDecoder().decode(SourceMetadata.self, from: Data(#"{"durationMs":1e22}"#.utf8))
        XCTAssertTrue(metadata.compatibilityIssues.contains { $0.contains("duration") })
    }

    func testCDL014015UnreadableSettingsFailClosedAndFieldEditsPreserveOtherWriters() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let settings = CaptureSettingsStore(layout: f.layout)
        XCTAssertEqual(try settings.loadChecked(), .default)
        try Data("{broken".utf8).write(to: f.layout.settingsURL)
        XCTAssertThrowsError(try settings.loadChecked())
        XCTAssertEqual(settings.load(), .unavailable)
        XCTAssertThrowsError(try f.engine.scan())
        try settings.update { $0.launchAtLoginRequested = true }
        XCTAssertFalse(settings.load().captureEnabled)
        XCTAssertTrue(settings.load().isPaused)
        let preserved = try FileManager.default.contentsOfDirectory(at: f.layout.applicationSupportURL, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("capture-settings-unreadable-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), Data("{broken".utf8))
        try settings.save(.default)
        let secondWriter = CaptureSettingsStore(layout: f.layout)
        _ = settings.load() // Represents the app's stale cached copy.
        try secondWriter.update { $0.isPaused = true }
        try settings.update { $0.launchAtLoginRequested = false }
        XCTAssertTrue(settings.load().isPaused)
        XCTAssertFalse(settings.load().launchAtLoginRequested)
    }

    func testCDL027UnchangedPartialCaptureDoesNotRewriteAudioManifestOrIndex() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("FIRST".utf8)], expectedSize: 11)
        _ = try f.engine.scan(now: Date(timeIntervalSince1970: 100))
        let before = try XCTUnwrap(f.store.record(id: "one"))
        let urls = [before.audioURL, before.manifestURL, before.metadataURL]
        let dates = try urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        for sourcePresent in [true, false] {
            if !sourcePresent { try FileManager.default.removeItem(at: source) }
            let scan = try f.engine.scan(now: Date(timeIntervalSince1970: 200))
            XCTAssertEqual(scan.updatedCount, 0)
            XCTAssertEqual(try f.store.record(id: "one"), before)
            XCTAssertEqual(try urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }, dates)
        }
    }

    func testCDL028BadDatabaseInitializationDoesNotLeakDescriptorsOrCrash() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("not sqlite".utf8).write(to: f.layout.databaseURL, options: .atomic)
        for _ in 0..<20 { XCTAssertThrowsError(try f.store.prepare()) }
    }

    private func staging(_ fixture: CaptureFixture, _ source: String) -> URL {
        fixture.layout.stagingURL.appendingPathComponent(DictationCaptureEngine.sha256(Data(source.utf8)))
    }

    private func sql(_ fixture: CaptureFixture, _ query: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.layout.databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK else {
            throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }
}
