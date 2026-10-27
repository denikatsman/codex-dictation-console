import Foundation
import XCTest
@testable import DictationArchiveCore

final class CaptureEngineTests: XCTestCase {
    func testUpstreamInterruptedStatusRemainsPartialEvenWhenAllSavedBytesExist() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "upstream-restart", id: "upstream-restart", transcript: "Saved before Codex restarted",
            chunks: [Data("audio".utf8)], status: "recording"
        )
        _ = try fixture.engine.scan()
        try fixture.writeMetadata(to: folder, id: "upstream-restart", transcript: "Saved before Codex restarted", size: 5, status: "interrupted")
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "upstream-restart"))
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(record.status, "interrupted")
        XCTAssertEqual(record.transcript, "Saved before Codex restarted")
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("audio".utf8))
    }

    func testChangedOptionalMetadataFieldCannotHideRecoverableTranscript() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "schema-change", id: "schema-change", transcript: "Keep these exact words",
            chunks: [Data("audio".utf8)]
        )
        let url = folder.appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        metadata["durationMs"] = "changed format"
        let raw = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        try raw.write(to: url, options: .atomic)
        let scan = try fixture.engine.scan()
        XCTAssertFalse(scan.errors.isEmpty)
        let record = try XCTUnwrap(fixture.store.record(id: "schema-change"))
        XCTAssertEqual(record.transcript, "Keep these exact words")
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(try Data(contentsOf: record.metadataURL), raw)
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("audio".utf8))
        XCTAssertFalse(try fixture.store.verifyArchivedFiles().isHealthy)
        try fixture.writeMetadata(to: folder, id: "schema-change", transcript: "Keep these exact words", size: 5)
        XCTAssertTrue(try fixture.engine.scan().errors.isEmpty)
        XCTAssertFalse(try XCTUnwrap(fixture.store.record(id: "schema-change")).isPartial)
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testUnknownSourceStatusReportsCompatibilityProblemWithoutLosingWords() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(
            sourceKey: "future-status", id: "future-status", transcript: "Still readable",
            chunks: [Data("audio".utf8)], status: "new-status-from-an-update"
        )
        let scan = try fixture.engine.scan()
        XCTAssertFalse(scan.errors.isEmpty)
        let record = try XCTUnwrap(fixture.store.record(id: "future-status"))
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(record.transcript, "Still readable")
        XCTAssertEqual(record.status, "new-status-from-an-update")
    }

    func testCapturePreservesSourceAndBuildsExactAudioArchive() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceFolder = try fixture.makeSourceRecording(
            sourceKey: "source-a",
            id: "record-a",
            transcript: "  Exact words\u{0000}\nwith café and 🎙️  ",
            chunks: [Data([0x1a, 0x45, 0xdf, 0xa3]), Data("second".utf8)]
        )
        let before = try fixture.snapshot(folder: sourceFolder)
        let now = Date(timeIntervalSince1970: 1_788_100_000)

        let first = try fixture.engine.scan(now: now)

        XCTAssertEqual(first.importedCount, 1)
        XCTAssertEqual(first.errors, [])
        XCTAssertEqual(try fixture.snapshot(folder: sourceFolder), before)
        let record = try XCTUnwrap(fixture.store.record(id: "record-a"))
        XCTAssertEqual(record.transcript, "  Exact words\u{0000}\nwith café and 🎙️  ")
        XCTAssertFalse(record.isPartial)
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data([0x1a, 0x45, 0xdf, 0xa3]) + Data("second".utf8))
        XCTAssertEqual(record.audioSizeBytes, 10)
        XCTAssertEqual(record.audioSHA256, try DictationCaptureEngine.sha256(fileAt: record.audioURL))
        XCTAssertEqual(try Data(contentsOf: record.metadataURL), before["metadata.json"])

        let manifestData = try Data(contentsOf: record.manifestURL)
        let manifest = try JSONDecoder.archiveDecoder.decode(RecordingManifest.self, from: manifestData)
        XCTAssertEqual(manifest.chunks.map(\.index), [0, 1])
        XCTAssertEqual(manifest.capturedSizeBytes, 10)
        XCTAssertFalse(manifest.isPartial)

        let second = try fixture.engine.scan(now: now.addingTimeInterval(1))
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.updatedCount, 0)
        XCTAssertEqual(try fixture.snapshot(folder: sourceFolder), before)
    }

    func testMetadataUpdatePreservesAudioAndExactReplacementText() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "source-b",
            id: "record-b",
            transcript: "First transcript",
            chunks: [Data("audio bytes".utf8)]
        )
        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        let firstRecord = try XCTUnwrap(fixture.store.record(id: "record-b"))
        let originalAudio = try Data(contentsOf: firstRecord.audioURL)
        try fixture.writeMetadata(
            to: folder,
            id: "record-b",
            transcript: "Second transcript — exact",
            size: originalAudio.count
        )

        let result = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(result.updatedCount, 1)
        let updated = try XCTUnwrap(fixture.store.record(id: "record-b"))
        XCTAssertEqual(updated.transcript, "Second transcript — exact")
        XCTAssertEqual(try Data(contentsOf: updated.audioURL), originalAudio)
        XCTAssertEqual(updated.firstCapturedAt, Date(timeIntervalSince1970: 100))
    }

    func testSourceCleanupCannotDowngradeACompleteArchive() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "source-cleanup",
            id: "record-cleanup",
            transcript: "Keep this exact transcript",
            chunks: [Data("complete audio".utf8)]
        )
        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        let original = try XCTUnwrap(fixture.store.record(id: "record-cleanup"))
        let originalMetadata = try Data(contentsOf: original.metadataURL)
        let originalAudio = try Data(contentsOf: original.audioURL)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("metadata.json"))
        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))
        try FileManager.default.removeItem(at: folder)
        let cleanupScan = try fixture.engine.scan(now: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(cleanupScan.updatedCount, 0)
        let preserved = try XCTUnwrap(fixture.store.record(id: "record-cleanup"))
        XCTAssertEqual(preserved.transcript, original.transcript)
        XCTAssertEqual(preserved.status, original.status)
        XCTAssertEqual(preserved.metadataSHA256, original.metadataSHA256)
        XCTAssertEqual(preserved.audioSHA256, original.audioSHA256)
        XCTAssertFalse(preserved.isPartial)
        XCTAssertEqual(try Data(contentsOf: preserved.metadataURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: preserved.audioURL), originalAudio)
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testEmptyMetadataCannotErasePreviouslyCapturedTranscript() throws {
        for partial in [false, true] {
            let fixture = try CaptureFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let folder = try fixture.makeSourceRecording(
                sourceKey: "regressed", id: "regressed", transcript: "Do not lose my words",
                chunks: [Data("audio".utf8)], expectedSize: partial ? 10 : 5
            )
            _ = try fixture.engine.scan()
            let original = try XCTUnwrap(fixture.store.record(id: "regressed"))
            let originalMetadata = try Data(contentsOf: original.metadataURL)
            for empty in ["", "  \n"] {
                try fixture.writeMetadata(to: folder, id: "regressed", transcript: empty, size: 5)
                _ = try fixture.engine.scan()
                let saved = try XCTUnwrap(fixture.store.record(id: "regressed"))
                XCTAssertEqual(saved.transcript, "Do not lose my words")
                XCTAssertEqual(try Data(contentsOf: saved.metadataURL), originalMetadata)
            }
            for invalid in [Data("{\"text\":".utf8), Data("{}".utf8)] {
                try invalid.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
                _ = try fixture.engine.scan()
                XCTAssertEqual(try fixture.store.record(id: "regressed")?.transcript, "Do not lose my words")
            }
            try FileManager.default.removeItem(at: folder)
            _ = try fixture.engine.scan()
            XCTAssertEqual(try fixture.store.record(id: "regressed")?.transcript, "Do not lose my words")
            XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
        }
    }

    func testTranscriptIsAvailableEvenWhenAnAudioChunkCannotBeCopied() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(
            sourceKey: "blocked-audio", id: "blocked-audio", transcript: "Recover without repeating",
            chunks: [Data("audio".utf8)]
        )
        // A directory in place of the destination chunk deterministically fails
        // the audio write, without relying on root-sensitive file permissions.
        let staging = fixture.layout.stagingURL
            .appendingPathComponent(DictationCaptureEngine.sha256(Data("blocked-audio".utf8)))
        let blocked = staging.appendingPathComponent("Chunks/0000000000.chunk")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let result = try fixture.engine.scan()
        XCTAssertFalse(result.errors.isEmpty)
        let record = try XCTUnwrap(fixture.store.record(id: "blocked-audio"))
        XCTAssertEqual(record.transcript, "Recover without repeating")
        XCTAssertTrue(record.isPartial)
        XCTAssertFalse(record.hasPlayableAudio)
        XCTAssertEqual(try fixture.store.records(search: "Recover").count, 1)

        try FileManager.default.removeItem(at: blocked)
        let retry = try fixture.engine.scan()
        XCTAssertTrue(retry.errors.isEmpty)
        let repaired = try XCTUnwrap(fixture.store.record(id: "blocked-audio"))
        XCTAssertFalse(repaired.isPartial)
        XCTAssertEqual(try Data(contentsOf: repaired.audioURL), Data("audio".utf8))
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testTranscriptRevisionsRemainRecoverableAndExportWithRecording() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "revisions", id: "revisions", transcript: "First exact words",
            chunks: [Data("audio".utf8)]
        )
        let first = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        _ = try fixture.engine.scan()
        try fixture.writeMetadata(to: folder, id: "revisions", transcript: "Revised exact words", size: 5)
        let second = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        _ = try fixture.engine.scan()
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "revisions"))
        XCTAssertEqual(record.transcript, "Revised exact words")
        let history = record.archiveFolderURL.appendingPathComponent("Metadata History")
        for data in [first, second] {
            let file = history.appendingPathComponent(DictationCaptureEngine.sha256(data) + ".json")
            XCTAssertEqual(try Data(contentsOf: file), data)
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 2)
        let exported = try ArchiveExporter(store: fixture.store).export(
            recordID: record.id, to: fixture.root.appendingPathComponent("Export")
        )
        XCTAssertEqual(try fixture.snapshot(folder: exported.appendingPathComponent("Metadata History")),
                       try fixture.snapshot(folder: history))
        let oldVersion = history.appendingPathComponent(DictationCaptureEngine.sha256(first) + ".json")
        try Data("damaged".utf8).write(to: oldVersion, options: .atomic)
        let verification = try fixture.store.verifyArchivedFiles()
        XCTAssertFalse(verification.isHealthy)
        XCTAssertTrue(verification.issues.contains { $0.message == "A Metadata History snapshot checksum does not match" })
        XCTAssertFalse(verification.issues.contains { $0.message.contains("First exact words") })
        try fixture.store.permanentlyDelete(id: record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertNil(try fixture.store.record(id: record.id))
    }

    func testPartialArchiveCompletesWhenMissingChunkArrives() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "source-c",
            id: "record-c",
            transcript: "Partial then complete",
            chunks: [Data("first".utf8)],
            expectedSize: 11
        )
        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(try XCTUnwrap(fixture.store.record(id: "record-c")).isPartial)

        try Data("second".utf8).write(to: folder.appendingPathComponent("0000000001.chunk"))
        let completed = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(completed.updatedCount, 1)
        let record = try XCTUnwrap(fixture.store.record(id: "record-c"))
        XCTAssertFalse(record.isPartial)
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("firstsecond".utf8))
    }

    func testDeletedSourceIDIsNotReimported() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(
            sourceKey: "source-d",
            id: "record-d",
            transcript: "Delete me",
            chunks: [Data("audio".utf8)]
        )
        _ = try fixture.engine.scan()
        try fixture.store.softDelete(id: "record-d")

        let result = try fixture.engine.scan()

        XCTAssertEqual(result.skippedTombstoneCount, 1)
        XCTAssertTrue(try fixture.store.records().isEmpty)
        XCTAssertEqual(try fixture.store.records(deleted: true).count, 1)
    }

    func testDisabledAndPausedSettingsDoNotCapture() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(
            sourceKey: "source-e",
            id: "record-e",
            transcript: "Do not capture yet",
            chunks: [Data("audio".utf8)]
        )
        let settingsStore = CaptureSettingsStore(layout: fixture.layout)
        try settingsStore.save(CaptureSettings(captureEnabled: false))
        XCTAssertEqual(try fixture.engine.scan().importedCount, 0)
        XCTAssertTrue(try fixture.store.records().isEmpty)

        try settingsStore.save(CaptureSettings(captureEnabled: true, isPaused: true))
        XCTAssertEqual(try fixture.engine.scan().importedCount, 0)
        XCTAssertTrue(try fixture.store.records().isEmpty)
    }

    func testRecordingRemainsPartialUntilTerminalMetadataArrives() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = try fixture.makeSourceRecording(
            sourceKey: "source-live",
            id: "record-live",
            transcript: "",
            chunks: [Data("live audio".utf8)],
            status: "recording"
        )

        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(try XCTUnwrap(fixture.store.record(id: "record-live")).isPartial)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.layout.stagingURL.path).count,
            1
        )

        try fixture.writeMetadata(
            to: folder,
            id: "record-live",
            transcript: "Final exact transcript",
            size: 10,
            status: "completed"
        )
        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))
        let completed = try XCTUnwrap(fixture.store.record(id: "record-live"))
        XCTAssertFalse(completed.isPartial)
        XCTAssertEqual(completed.transcript, "Final exact transcript")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.layout.stagingURL.path).isEmpty)
    }

    func testMonitorNoticesSourceCreatedAfterLaunchBeforeReconciliationTimer() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.source)
        let initial = expectation(description: "initial scan without source")
        let captured = expectation(description: "new source captured promptly")
        let initialFlag = OneShotFlag()
        let captureFlag = OneShotFlag()
        let monitor = CaptureMonitor(engine: fixture.engine) { result in
            guard case .success(let scan) = result else { return }
            if initialFlag.claim() { initial.fulfill() }
            if scan.importedCount > 0, captureFlag.claim() { captured.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }
        wait(for: [initial], timeout: 2)
        _ = try fixture.makeSourceRecording(
            sourceKey: "late-source", id: "late-source", transcript: "First dictation after login",
            chunks: [Data("audio".utf8)]
        )
        wait(for: [captured], timeout: 2)
        XCTAssertEqual(try fixture.store.records().count, 1)
    }

    func testTopLevelScanFailureReplacesPreviouslyHealthyStatusAndCanRecover() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.engine.scan()
        let database = fixture.layout.databaseURL
        let saved = database.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: database, to: saved)
        try Data("invalid SQLite database".utf8).write(to: database)
        XCTAssertThrowsError(try fixture.engine.scan())
        XCTAssertNotNil(CaptureStatusStore(layout: fixture.layout).load()?.lastError)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: saved, to: database)
        _ = try fixture.engine.scan()
        XCTAssertNil(CaptureStatusStore(layout: fixture.layout).load()?.lastError)
    }

    func testStoppingMonitorCapturesChangesStillWaitingForDebounce() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = expectation(description: "initial scan")
        let flag = OneShotFlag()
        let monitor = CaptureMonitor(engine: fixture.engine) { _ in
            if flag.claim() { initial.fulfill() }
        }
        monitor.start()
        wait(for: [initial], timeout: 2)
        _ = try fixture.makeSourceRecording(
            sourceKey: "at-quit", id: "at-quit", transcript: "Last words before quitting",
            chunks: [Data("audio".utf8)], status: "recording"
        )
        monitor.stop(capturePendingChanges: true)
        let record = try XCTUnwrap(fixture.store.record(id: "at-quit"))
        XCTAssertEqual(record.transcript, "Last words before quitting")
        XCTAssertTrue(record.isPartial)
    }

    func testAdditionalOrphanedAudioSurvivesRepeatedSourceInterruption() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = fixture.source.appendingPathComponent("interrupted")
        let first = Data("first audio".utf8)
        let second = Data(" then more audio".utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try first.write(to: folder.appendingPathComponent("0000000000.chunk"))
        _ = try fixture.engine.scan()
        try FileManager.default.removeItem(at: folder)
        _ = try fixture.engine.scan()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fixture.store.record(id: "interrupted")).audioURL), first)
        _ = try fixture.engine.scan() // Idle reconciliation must not discard staged audio.
        // Recreate a writer after interruption. The first chunk is no longer
        // available from the source; it must be retained from staging.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try second.write(to: folder.appendingPathComponent("0000000001.chunk"))
        _ = try fixture.engine.scan()
        try FileManager.default.removeItem(at: folder)
        let restarted = DictationCaptureEngine(sourceURL: fixture.source, layout: fixture.layout)
        _ = try restarted.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "interrupted"))
        XCTAssertEqual(try Data(contentsOf: record.audioURL), first + second)
        XCTAssertTrue(record.isPartial)
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testMonitorCapturesNewFolderFromFileSystemEvent() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initialScan = expectation(description: "initial scan")
        let eventCapture = expectation(description: "event-driven capture")
        let initialFlag = OneShotFlag()
        let monitor = CaptureMonitor(engine: fixture.engine) { result in
            guard case .success(let scan) = result else { return }
            if initialFlag.claim() { initialScan.fulfill() }
            if scan.importedCount == 1 { eventCapture.fulfill() }
        }
        monitor.start()
        wait(for: [initialScan], timeout: 2)

        _ = try fixture.makeSourceRecording(
            sourceKey: "source-event",
            id: "record-event",
            transcript: "Captured from an event",
            chunks: [Data("event audio".utf8)]
        )

        wait(for: [eventCapture], timeout: 4)
        monitor.stop()
        XCTAssertEqual(try fixture.store.records().map(\.id), ["record-event"])
    }

    func testContinuousSourceWritesDoNotPostponeCaptureUntilTheTimer() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initialScan = expectation(description: "initial scan")
        let captured = expectation(description: "capture during continuous writes")
        let initialFlag = OneShotFlag()
        let captureFlag = OneShotFlag()
        let monitor = CaptureMonitor(engine: fixture.engine) { result in
            guard case .success(let scan) = result else { return }
            if initialFlag.claim() { initialScan.fulfill() }
            if scan.importedCount > 0, captureFlag.claim() { captured.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }
        wait(for: [initialScan], timeout: 2)
        _ = try fixture.makeSourceRecording(
            sourceKey: "busy", id: "busy", transcript: "Save while the source is busy",
            chunks: [Data("audio".utf8)]
        )
        // Keep changing the root directory for longer than the capture deadline.
        // A trailing debounce would continually reset that deadline.
        let writer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "CaptureTest.Writer"))
        writer.schedule(deadline: .now(), repeating: .milliseconds(25))
        writer.setEventHandler {
            try? Data("event".utf8).write(to: fixture.source.appendingPathComponent("noise"), options: .atomic)
        }
        writer.resume()
        defer { writer.cancel() }
        wait(for: [captured], timeout: 1.5)
        XCTAssertEqual(try fixture.store.record(id: "busy")?.transcript, "Save while the source is busy")
    }

    func testWakeReconciliationReopensAReplacedSourceAndContinuesWatching() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = expectation(description: "initial scan")
        let firstCapture = expectation(description: "capture after wake")
        let secondCapture = expectation(description: "event after wake")
        let initialFlag = OneShotFlag()
        let firstFlag = OneShotFlag()
        let secondFlag = OneShotFlag()
        let monitor = CaptureMonitor(engine: fixture.engine) { result in
            guard case .success(let scan) = result else { return }
            if initialFlag.claim() { initial.fulfill() }
            if scan.importedCount > 0 {
                if firstFlag.claim() { firstCapture.fulfill() }
                else if secondFlag.claim() { secondCapture.fulfill() }
            }
        }
        monitor.start()
        defer { monitor.stop() }
        wait(for: [initial], timeout: 2)
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("Old Source"))
        _ = try fixture.makeSourceRecording(
            sourceKey: "wake", id: "wake", transcript: "Captured after waking",
            chunks: [Data("audio".utf8)]
        )
        monitor.rescanAfterWake()
        wait(for: [firstCapture], timeout: 2)
        _ = try fixture.makeSourceRecording(
            sourceKey: "after-wake", id: "after-wake", transcript: "Still watching",
            chunks: [Data("audio".utf8)]
        )
        wait(for: [secondCapture], timeout: 2)
        XCTAssertEqual(try fixture.store.records().count, 2)
    }

    func testOrphanedAudioChunksRemainAvailableAsPartialRecord() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceFolder = fixture.source.appendingPathComponent("orphan-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let audio = Data([0x1a, 0x45, 0xdf, 0xa3, 0x55, 0x66])
        try audio.write(to: sourceFolder.appendingPathComponent("0000000000.chunk"))

        let staged = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(staged.importedCount, 0)
        XCTAssertTrue(try fixture.store.records().isEmpty)
        try FileManager.default.removeItem(at: sourceFolder)

        let recovered = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(recovered.importedCount, 1)
        let record = try XCTUnwrap(fixture.store.record(id: "orphan-source"))
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(record.status, "source_missing")
        XCTAssertEqual(record.transcript, "")
        XCTAssertNil(record.metadataSHA256)
        XCTAssertEqual(try Data(contentsOf: record.audioURL), audio)
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testMalformedMetadataAndAudioAreRetainedAfterSourceDisappears() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceFolder = fixture.source.appendingPathComponent("malformed-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let audio = Data("orphaned audio bytes".utf8)
        let malformedMetadata = Data(#"{"text":"unfinished""#.utf8)
        try audio.write(to: sourceFolder.appendingPathComponent("0000000000.chunk"))
        try malformedMetadata.write(to: sourceFolder.appendingPathComponent("metadata.json"))

        let staged = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(staged.importedCount, 0)
        try FileManager.default.removeItem(at: sourceFolder)
        let recovered = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(recovered.importedCount, 1)
        let record = try XCTUnwrap(fixture.store.record(id: "malformed-source"))
        XCTAssertEqual(record.status, "metadata_unreadable")
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(try Data(contentsOf: record.audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: record.metadataURL), malformedMetadata)
        XCTAssertEqual(record.metadataSHA256, DictationCaptureEngine.sha256(malformedMetadata))
        let verification = try fixture.store.verifyArchivedFiles()
        XCTAssertFalse(verification.isHealthy)
        XCTAssertTrue(verification.issues.contains { $0.message.contains("could not be decoded") })
    }

    func testOrphanedAudioCanCompleteWhenSourceMetadataLaterAppears() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceFolder = fixture.source.appendingPathComponent("returning-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let audio = Data("recoverable audio".utf8)
        try audio.write(to: sourceFolder.appendingPathComponent("0000000000.chunk"))

        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 100))
        try FileManager.default.removeItem(at: sourceFolder)
        _ = try fixture.engine.scan(now: Date(timeIntervalSince1970: 200))
        let orphan = try XCTUnwrap(fixture.store.record(id: "returning-source"))
        XCTAssertTrue(orphan.isPartial)

        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try audio.write(to: sourceFolder.appendingPathComponent("0000000000.chunk"))
        try fixture.writeMetadata(
            to: sourceFolder,
            id: "canonical-record-id",
            transcript: "The metadata arrived later",
            size: audio.count
        )

        let completed = try fixture.engine.scan(now: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(completed.updatedCount, 1)
        XCTAssertNil(try fixture.store.record(id: "canonical-record-id"))
        let record = try XCTUnwrap(fixture.store.record(sourceKey: "returning-source"))
        XCTAssertEqual(record.id, "returning-source")
        XCTAssertEqual(record.transcript, "The metadata arrived later")
        XCTAssertFalse(record.isPartial)
        XCTAssertEqual(record.firstCapturedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try Data(contentsOf: record.audioURL), audio)
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testConcurrentScansShareOneArchiveSafely() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = Data(repeating: 0x5a, count: 32_768)
        _ = try fixture.makeSourceRecording(
            sourceKey: "source-concurrent",
            id: "record-concurrent",
            transcript: "One exact record from concurrent scanners",
            chunks: [audio]
        )
        let engines = (0..<8).map { _ in
            DictationCaptureEngine(sourceURL: fixture.source, layout: fixture.layout)
        }

        let results = try await withThrowingTaskGroup(of: CaptureScanResult.self) { group in
            for engine in engines {
                group.addTask { try engine.scan() }
            }
            var scans: [CaptureScanResult] = []
            for try await result in group { scans.append(result) }
            return scans
        }

        XCTAssertEqual(results.reduce(0) { $0 + $1.importedCount }, 1)
        XCTAssertTrue(results.allSatisfy(\.errors.isEmpty))
        let records = try fixture.store.records()
        XCTAssertEqual(records.map(\.id), ["record-concurrent"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(records.first).audioURL), audio)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.layout.stagingURL.path).isEmpty
        )
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().isHealthy)
    }

    func testPermanentDeletionCannotRaceWithCaptureReimport() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(
            sourceKey: "source-delete-race",
            id: "record-delete-race",
            transcript: "Delete once and keep it deleted",
            chunks: [Data(repeating: 0x41, count: 262_144)]
        )
        _ = try fixture.engine.scan()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try fixture.engine.scan() }
            group.addTask { try fixture.store.permanentlyDelete(id: "record-delete-race") }
            try await group.waitForAll()
        }

        XCTAssertNil(try fixture.store.record(id: "record-delete-race"))
        XCTAssertTrue(try fixture.store.isTombstoned(sourceKey: "source-delete-race"))
        XCTAssertTrue(try fixture.engine.scan().skippedTombstoneCount > 0)
        XCTAssertNil(try fixture.store.record(id: "record-delete-race"))
    }
}

private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var wasClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !wasClaimed else { return false }
        wasClaimed = true
        return true
    }
}

struct CaptureFixture {
    let root: URL
    let source: URL
    let layout: ArchiveLayout
    let engine: DictationCaptureEngine
    let store: ArchiveStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexDictationCaptureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        source = root.appendingPathComponent("Source", isDirectory: true)
        layout = ArchiveLayout(applicationSupportURL: root.appendingPathComponent("Support"))
        engine = DictationCaptureEngine(sourceURL: source, layout: layout)
        store = ArchiveStore(layout: layout)
        try store.prepare()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func makeSourceRecording(
        sourceKey: String,
        id: String,
        transcript: String,
        chunks: [Data],
        expectedSize: Int? = nil,
        status: String = "completed"
    ) throws -> URL {
        let folder = source.appendingPathComponent(sourceKey, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, data) in chunks.enumerated() {
            try data.write(
                to: folder.appendingPathComponent(String(format: "%010d.chunk", index))
            )
        }
        try writeMetadata(
            to: folder,
            id: id,
            transcript: transcript,
            size: expectedSize ?? chunks.reduce(0) { $0 + $1.count },
            status: status
        )
        return folder
    }

    func writeMetadata(
        to folder: URL,
        id: String,
        transcript: String,
        size: Int,
        status: String = "completed"
    ) throws {
        let object: [String: Any] = [
            "createdAtMs": 1_788_000_000_000,
            "durationMs": 12_345,
            "id": id,
            "mimeType": "audio/webm;codecs=opus",
            "sizeBytes": size,
            "status": status,
            "surface": "composer",
            "text": transcript
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
    }

    func snapshot(folder: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }
}
