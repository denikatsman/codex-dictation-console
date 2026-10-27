import Foundation
import XCTest
@testable import DictationArchiveCore

final class ArchiveStoreTests: XCTestCase {
    func testArchiveDatabaseFilesUsePrivatePermissions() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ArchiveStore(layout: fixture.layout)

        try store.prepare()

        let databasePermissions = try FileManager.default.attributesOfItem(
            atPath: fixture.layout.databaseURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(databasePermissions?.intValue, 0o600)
        for suffix in ["-wal", "-shm"] {
            let path = fixture.layout.databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                    as? NSNumber
                XCTAssertEqual(permissions?.intValue, 0o600)
            }
        }
    }

    func testStoreSearchDeleteRestoreAndPermanentDeletion() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ArchiveStore(layout: fixture.layout)
        try store.prepare()
        let folder = fixture.layout.recordingsURL.appendingPathComponent("record", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("audio.webm"))
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let record = ArchivedDictationRecord(
            id: "record-id",
            sourceKey: "source-key",
            createdAt: now,
            durationSeconds: 12.5,
            status: "completed",
            surface: .composer,
            transcript: "Exact café transcript with a microphone",
            mimeType: "audio/webm;codecs=opus",
            audioSizeBytes: 5,
            expectedSizeBytes: 5,
            archiveFolderURL: folder,
            audioSHA256: "audio-hash",
            metadataSHA256: "metadata-hash",
            isPartial: false,
            firstCapturedAt: now,
            updatedAt: now
        )

        try store.upsert(record)

        XCTAssertEqual(try store.records(), [record])
        XCTAssertEqual(try store.recordCount(), 1)
        XCTAssertEqual(try store.recordCount(deleted: true), 0)
        XCTAssertEqual(try store.records(search: "café microphone").map(\.id), [record.id])
        XCTAssertTrue(try store.records(search: "missing").isEmpty)
        XCTAssertEqual(try store.quickCheck(), "ok")

        try store.softDelete(id: record.id, at: now.addingTimeInterval(5))
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertEqual(try store.recordCount(), 0)
        XCTAssertEqual(try store.recordCount(deleted: true), 1)
        XCTAssertEqual(try store.records(deleted: true).map(\.id), [record.id])
        XCTAssertTrue(try store.isTombstoned(sourceKey: record.sourceKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try store.restore(id: record.id, at: now.addingTimeInterval(10))
        XCTAssertEqual(try store.records().map(\.id), [record.id])
        XCTAssertFalse(try store.isTombstoned(sourceKey: record.sourceKey))

        try store.softDelete(id: record.id, at: now.addingTimeInterval(15))
        try store.permanentlyDelete(id: record.id, at: now.addingTimeInterval(20))
        XCTAssertNil(try store.record(id: record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(try store.isTombstoned(sourceKey: record.sourceKey))
        XCTAssertEqual(try store.tombstoneCount(), 1)
    }

    func testUpsertPreservesOriginalCaptureTime() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ArchiveStore(layout: fixture.layout)
        let folder = fixture.layout.recordingsURL.appendingPathComponent("record", isDirectory: true)
        let first = Date(timeIntervalSince1970: 100)
        let updated = Date(timeIntervalSince1970: 200)
        let initial = fixture.record(folder: folder, firstCapturedAt: first, updatedAt: first)
        try store.upsert(initial)
        var replacement = fixture.record(folder: folder, firstCapturedAt: updated, updatedAt: updated)
        replacement = ArchivedDictationRecord(
            id: replacement.id,
            sourceKey: replacement.sourceKey,
            createdAt: replacement.createdAt,
            durationSeconds: replacement.durationSeconds,
            status: replacement.status,
            surface: replacement.surface,
            transcript: "Updated exact transcript",
            mimeType: replacement.mimeType,
            audioSizeBytes: replacement.audioSizeBytes,
            expectedSizeBytes: replacement.expectedSizeBytes,
            archiveFolderURL: replacement.archiveFolderURL,
            audioSHA256: replacement.audioSHA256,
            metadataSHA256: "new-hash",
            isPartial: replacement.isPartial,
            firstCapturedAt: replacement.firstCapturedAt,
            updatedAt: replacement.updatedAt
        )
        try store.upsert(replacement)

        let loaded = try XCTUnwrap(store.record(id: initial.id))
        XCTAssertEqual(loaded.firstCapturedAt, first)
        XCTAssertEqual(loaded.updatedAt, updated)
        XCTAssertEqual(loaded.transcript, "Updated exact transcript")
    }

    func testFileVerificationDetectsAudioCorruption() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ArchiveStore(layout: fixture.layout)
        try store.prepare()
        let folder = fixture.layout.recordingsURL.appendingPathComponent("verified", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = Data("verified audio".utf8)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "createdAtMs": 1_000,
            "durationMs": 1_000,
            "id": "verified-id",
            "mimeType": "audio/webm;codecs=opus",
            "sizeBytes": audio.count,
            "status": "completed",
            "surface": "composer",
            "text": "Verified"
        ])
        try audio.write(to: folder.appendingPathComponent("audio.webm"))
        try metadata.write(to: folder.appendingPathComponent("metadata.json"))
        let manifest = RecordingManifest(
            recordID: "verified-id",
            sourceKey: "verified-source",
            capturedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            sourceStatus: "completed",
            mimeType: "audio/webm;codecs=opus",
            expectedSizeBytes: Int64(audio.count),
            capturedSizeBytes: Int64(audio.count),
            isPartial: false,
            audioSHA256: DictationCaptureEngine.sha256(audio),
            metadataSHA256: DictationCaptureEngine.sha256(metadata),
            chunks: [
                AudioChunkManifest(
                    filename: "0000000000.chunk",
                    index: 0,
                    sizeBytes: Int64(audio.count),
                    sha256: DictationCaptureEngine.sha256(audio)
                )
            ]
        )
        try JSONEncoder.archiveEncoder.encode(manifest).write(
            to: folder.appendingPathComponent("manifest.json")
        )
        let record = ArchivedDictationRecord(
            id: manifest.recordID,
            sourceKey: manifest.sourceKey,
            createdAt: Date(timeIntervalSince1970: 1),
            durationSeconds: 1,
            status: "completed",
            surface: .composer,
            transcript: "Verified",
            mimeType: manifest.mimeType,
            audioSizeBytes: Int64(audio.count),
            expectedSizeBytes: Int64(audio.count),
            archiveFolderURL: folder,
            audioSHA256: manifest.audioSHA256,
            metadataSHA256: manifest.metadataSHA256,
            isPartial: false,
            firstCapturedAt: manifest.capturedAt,
            updatedAt: manifest.updatedAt
        )
        try store.upsert(record)
        XCTAssertTrue(try store.verifyArchivedFiles().isHealthy)

        try Data("corrupted audio".utf8).write(to: record.audioURL, options: .atomic)

        let verification = try store.verifyArchivedFiles()
        XCTAssertFalse(verification.isHealthy)
        XCTAssertTrue(verification.issues.contains { $0.message.contains("checksum") })

        try audio.write(to: record.audioURL, options: .atomic)
        let mismatchedManifest = RecordingManifest(
            recordID: manifest.recordID,
            sourceKey: "wrong-source",
            capturedAt: manifest.capturedAt,
            updatedAt: manifest.updatedAt,
            sourceStatus: manifest.sourceStatus,
            mimeType: manifest.mimeType,
            expectedSizeBytes: manifest.expectedSizeBytes,
            capturedSizeBytes: manifest.capturedSizeBytes,
            isPartial: manifest.isPartial,
            audioSHA256: manifest.audioSHA256,
            metadataSHA256: manifest.metadataSHA256,
            chunks: manifest.chunks
        )
        try JSONEncoder.archiveEncoder.encode(mismatchedManifest).write(
            to: record.manifestURL,
            options: .atomic
        )
        let manifestVerification = try store.verifyArchivedFiles()
        XCTAssertFalse(manifestVerification.isHealthy)
        XCTAssertTrue(manifestVerification.issues.contains { $0.message.contains("source key") })
    }
}

struct ArchiveFixture {
    let root: URL
    let layout: ArchiveLayout

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexDictationLabTests-\(UUID().uuidString)",
            isDirectory: true
        )
        layout = ArchiveLayout(applicationSupportURL: root.appendingPathComponent("Support"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func record(
        folder: URL,
        firstCapturedAt: Date,
        updatedAt: Date
    ) -> ArchivedDictationRecord {
        ArchivedDictationRecord(
            id: "record-id",
            sourceKey: "source-key",
            createdAt: Date(timeIntervalSince1970: 50),
            durationSeconds: 2,
            status: "completed",
            surface: .global,
            transcript: "Original",
            mimeType: "audio/webm;codecs=opus",
            audioSizeBytes: 10,
            expectedSizeBytes: 10,
            archiveFolderURL: folder,
            audioSHA256: "audio",
            metadataSHA256: "metadata",
            isPartial: false,
            firstCapturedAt: firstCapturedAt,
            updatedAt: updatedAt
        )
    }
}
