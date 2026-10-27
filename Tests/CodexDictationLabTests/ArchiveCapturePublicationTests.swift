import Foundation
import XCTest
@testable import DictationArchiveCore

final class ArchiveCapturePublicationTests: XCTestCase {
    func testGrowingEarlierChunkPreservesAllPreviouslyCapturedBytes() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try fixture.makeSourceRecording(sourceKey: "source", id: "record", transcript: "Words",
            chunks: [Data("first".utf8), Data("second".utf8)], status: "recording")
        XCTAssertTrue(try fixture.engine.scan().errors.isEmpty)
        try Data("first extended".utf8).write(to: source.appendingPathComponent("0000000000.chunk"))
        try fixture.writeMetadata(to: source, id: "record", transcript: "Words", size: 20)
        let result = try fixture.engine.scan()
        XCTAssertTrue(result.errors.isEmpty, result.errors.joined(separator: "\n"))
        let record = try XCTUnwrap(fixture.store.record(id: "record"))
        XCTAssertEqual(try Data(contentsOf: record.audioURL), Data("first extendedsecond".utf8))
        XCTAssertFalse(record.isPartial)
    }

    func testNextScanResumesReadyUpdateWithAndWithoutTheSourceFolder() throws {
        for removeSource in [false, true] {
            let fixture = try PublicationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
            try fixture.publication.prepare(record: fixture.new, manifest: fixture.manifest,
                                            metadata: fixture.metadata, audio: fixture.audio, in: fixture.staging)
            try JSONSerialization.data(withJSONObject: ["sourceKey": "source"]).write(to: fixture.staging.appendingPathComponent("source.json"))
            XCTAssertThrowsError(try fixture.publication.resume(in: fixture.staging) { name in
                if name == "audio.webm" { throw CocoaError(.userCancelled) }
            })
            if removeSource { try FileManager.default.removeItem(at: fixture.capture.source.appendingPathComponent("source")) }
            let result = try fixture.capture.engine.scan(now: Date(timeIntervalSince1970: 300))
            XCTAssertTrue(result.errors.isEmpty, result.errors.joined(separator: "\n"))
            XCTAssertEqual(try fixture.capture.store.record(id: "record")?.transcript, "Completed words")
            XCTAssertTrue(try fixture.capture.store.verifyArchivedFiles().isHealthy)
        }
    }

    func testInterruptedPublicationResumesAfterEachFileAndIndexCommit() throws {
        for interruption in ["audio.webm", "metadata.json", "manifest.json", "index"] {
            let fixture = try PublicationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
            let publication = fixture.publication
            try publication.prepare(record: fixture.new, manifest: fixture.manifest,
                                    metadata: fixture.metadata, audio: fixture.audio, in: fixture.staging)
            XCTAssertThrowsError(try publication.resume(in: fixture.staging) { name in
                if name == interruption { throw CocoaError(.userCancelled) }
            })
            XCTAssertTrue(try publication.resume(in: fixture.staging))
            XCTAssertFalse(try publication.resume(in: fixture.staging))
            XCTAssertEqual(try fixture.capture.store.record(id: "record"), fixture.new)
            XCTAssertTrue(try fixture.capture.store.verifyArchivedFiles().isHealthy)
            XCTAssertEqual(try Data(contentsOf: fixture.new.audioURL), Data("firstsecond".utf8))
        }
    }

    func testMetadataOnlyPublicationResumesWithoutReplacingAudio() throws {
        let fixture = try PublicationFixture(metadataOnly: true)
        defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
        try fixture.publication.prepare(record: fixture.new, manifest: fixture.manifest,
                                        metadata: fixture.metadata, audio: nil, in: fixture.staging)
        XCTAssertThrowsError(try fixture.publication.resume(in: fixture.staging) { name in
            if name == "metadata.json" { throw CocoaError(.userCancelled) }
        })
        XCTAssertTrue(try fixture.publication.resume(in: fixture.staging))
        XCTAssertTrue(try fixture.capture.store.verifyArchivedFiles().isHealthy)
        XCTAssertEqual(try Data(contentsOf: fixture.new.audioURL), Data("first".utf8))
        XCTAssertEqual(try fixture.capture.store.record(id: "record")?.transcript, "Completed words")
    }

    func testCorruptPendingAudioIsPreservedAndNeverPublished() throws {
        let fixture = try PublicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
        try fixture.publication.prepare(record: fixture.new, manifest: fixture.manifest,
                                        metadata: fixture.metadata, audio: fixture.audio, in: fixture.staging)
        let candidate = fixture.staging.appendingPathComponent(".publication/audio.webm")
        try Data("corrupt".utf8).write(to: candidate)
        XCTAssertThrowsError(try fixture.publication.resume(in: fixture.staging))
        XCTAssertEqual(try fixture.capture.store.record(id: "record"), fixture.old)
        XCTAssertEqual(try Data(contentsOf: fixture.old.audioURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: candidate), Data("corrupt".utf8))
    }

    func testDeletionNeverResurrectsPendingCaptureAndPermanentDeletionRemovesIt() throws {
        let fixture = try PublicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
        try fixture.publication.prepare(record: fixture.new, manifest: fixture.manifest,
                                        metadata: fixture.metadata, audio: fixture.audio, in: fixture.staging)
        try fixture.capture.store.softDelete(id: "record")
        XCTAssertFalse(try fixture.publication.resume(in: fixture.staging))
        XCTAssertTrue(try XCTUnwrap(fixture.capture.store.record(id: "record")).isDeleted)
        try fixture.capture.store.permanentlyDelete(id: "record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        XCTAssertNil(try fixture.capture.store.record(id: "record"))
    }

    func testScanRecoversLegacyManifestAheadOfIndexAndPreservesPriorIndex() throws {
        let fixture = try PublicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
        try fixture.publishLegacyFiles()
        let result = try fixture.capture.engine.scan(now: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(result.errors.isEmpty, result.errors.joined(separator: "\n"))
        let record = try XCTUnwrap(fixture.capture.store.record(id: "record"))
        XCTAssertEqual(record.transcript, "Completed words")
        XCTAssertFalse(record.isPartial)
        XCTAssertTrue(try fixture.capture.store.verifyArchivedFiles().isHealthy)
        let history = try FileManager.default.contentsOfDirectory(at: record.archiveFolderURL.appendingPathComponent("Index History"), includingPropertiesForKeys: nil)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ArchivedDictationRecord.self, from: Data(contentsOf: history[0])), fixture.old)
    }

    func testLegacyRecoveryRejectsCorruptChunkProofAndConflictingIndexedAudio() throws {
        for corruptChunk in [true, false] {
            let fixture = try PublicationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.capture.root) }
            try fixture.publishLegacyFiles()
            if corruptChunk {
                var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.old.manifestURL)) as? [String: Any])
                var chunks = try XCTUnwrap(raw["chunks"] as? [[String: Any]])
                chunks[0]["sha256"] = String(repeating: "0", count: 64)
                raw["chunks"] = chunks
                try JSONSerialization.data(withJSONObject: raw).write(to: fixture.old.manifestURL, options: .atomic)
            } else {
                let other = ArchivedDictationRecord(id: fixture.old.id, sourceKey: fixture.old.sourceKey,
                    createdAt: fixture.old.createdAt, durationSeconds: fixture.old.durationSeconds,
                    status: fixture.old.status, surface: fixture.old.surface, transcript: fixture.old.transcript,
                    mimeType: fixture.old.mimeType, audioSizeBytes: fixture.old.audioSizeBytes,
                    expectedSizeBytes: fixture.old.expectedSizeBytes, archiveFolderURL: fixture.old.archiveFolderURL,
                    audioSHA256: DictationCaptureEngine.sha256(Data("other".utf8)), metadataSHA256: fixture.old.metadataSHA256,
                    isPartial: true, firstCapturedAt: fixture.old.firstCapturedAt, updatedAt: fixture.old.updatedAt)
                try fixture.capture.store.upsert(other)
            }
            XCTAssertFalse(try fixture.capture.engine.scan().errors.isEmpty)
            XCTAssertEqual(try fixture.capture.store.record(id: "record")?.updatedAt, fixture.old.updatedAt)
            XCTAssertEqual(try Data(contentsOf: fixture.old.audioURL), Data("firstsecond".utf8))
        }
    }
}

private struct PublicationFixture {
    let capture: CaptureFixture
    let old: ArchivedDictationRecord
    let new: ArchivedDictationRecord
    let manifest: RecordingManifest
    let metadata: Data
    let audio: URL
    let staging: URL
    var publication: ArchiveCapturePublication { ArchiveCapturePublication(layout: capture.layout, store: capture.store) }

    init(metadataOnly: Bool = false) throws {
        capture = try CaptureFixture()
        let source = try capture.makeSourceRecording(sourceKey: "source", id: "record", transcript: "Initial words",
            chunks: [Data("first".utf8)], status: metadataOnly ? "completed" : "recording")
        _ = try capture.engine.scan(now: Date(timeIntervalSince1970: 100))
        old = try XCTUnwrap(capture.store.record(id: "record"))
        let oldMetadata = try Data(contentsOf: old.metadataURL)
        let oldManifest = try Data(contentsOf: old.manifestURL)
        let oldAudio = try Data(contentsOf: old.audioURL)
        if !metadataOnly { try Data("second".utf8).write(to: source.appendingPathComponent("0000000001.chunk")) }
        try capture.writeMetadata(to: source, id: "record", transcript: "Completed words", size: metadataOnly ? 5 : 11)
        XCTAssertTrue(try capture.engine.scan(now: Date(timeIntervalSince1970: 200)).errors.isEmpty)
        new = try XCTUnwrap(capture.store.record(id: "record"))
        manifest = try JSONDecoder.archiveDecoder.decode(RecordingManifest.self, from: Data(contentsOf: new.manifestURL))
        metadata = try Data(contentsOf: new.metadataURL)
        audio = capture.root.appendingPathComponent("candidate.webm")
        try Data(contentsOf: new.audioURL).write(to: audio)
        try oldMetadata.write(to: old.metadataURL, options: .atomic)
        try oldManifest.write(to: old.manifestURL, options: .atomic)
        try oldAudio.write(to: old.audioURL, options: .atomic)
        try capture.store.upsert(old)
        staging = capture.layout.stagingURL.appendingPathComponent(DictationCaptureEngine.sha256(Data("source".utf8)))
    }

    func publishLegacyFiles() throws {
        try Data(contentsOf: audio).write(to: old.audioURL, options: .atomic)
        try metadata.write(to: old.metadataURL, options: .atomic)
        try JSONEncoder.archiveEncoder.encode(manifest).write(to: old.manifestURL, options: .atomic)
    }
}
