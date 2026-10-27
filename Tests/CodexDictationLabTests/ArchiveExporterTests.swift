import Foundation
import XCTest
@testable import DictationArchiveCore

final class ArchiveExporterTests: XCTestCase {
    func testSingleAndBulkExportAreExactAndNeverOverwrite() throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ArchiveStore(layout: fixture.layout)
        try store.prepare()
        let folder = fixture.layout.recordingsURL.appendingPathComponent("archive-record")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = Data([0x1a, 0x45, 0xdf, 0xa3, 0x01])
        let metadata = Data(#"{"text":"source"}"#.utf8)
        try audio.write(to: folder.appendingPathComponent("audio.webm"))
        try metadata.write(to: folder.appendingPathComponent("metadata.json"))
        let record = ArchivedDictationRecord(
            id: "../../export-record",
            sourceKey: "export-source",
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            durationSeconds: 3,
            status: "completed",
            surface: .composer,
            transcript: "  Exact export\nwith café 🎙️  ",
            mimeType: "audio/webm;codecs=opus",
            audioSizeBytes: Int64(audio.count),
            expectedSizeBytes: Int64(audio.count),
            archiveFolderURL: folder,
            audioSHA256: DictationCaptureEngine.sha256(audio),
            metadataSHA256: DictationCaptureEngine.sha256(metadata),
            isPartial: false,
            firstCapturedAt: Date(timeIntervalSince1970: 1_788_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_788_000_002)
        )
        let manifest = try JSONEncoder.archiveEncoder.encode(RecordingManifest(
            recordID: record.id, sourceKey: record.sourceKey,
            capturedAt: record.firstCapturedAt, updatedAt: record.updatedAt,
            sourceStatus: record.status, mimeType: record.mimeType,
            expectedSizeBytes: record.expectedSizeBytes, capturedSizeBytes: record.audioSizeBytes,
            isPartial: false, audioSHA256: record.audioSHA256, metadataSHA256: record.metadataSHA256,
            chunks: [AudioChunkManifest(filename: "0000000000.chunk", index: 0,
                                       sizeBytes: record.audioSizeBytes, sha256: record.audioSHA256!)]
        ))
        try manifest.write(to: record.manifestURL)
        try store.upsert(record)
        let destination = fixture.root.appendingPathComponent("Exports")
        let exporter = ArchiveExporter(store: store)

        let first = try exporter.export(recordID: record.id, to: destination)
        let second = try exporter.export(recordID: record.id, to: destination)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(second.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("audio.webm")), audio)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("metadata.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(
            try String(contentsOf: first.appendingPathComponent("transcript.txt"), encoding: .utf8),
            record.transcript
        )

        let bulk = try exporter.exportAll(
            to: destination,
            now: Date(timeIntervalSince1970: 1_788_000_100)
        )
        let lines = try String(
            contentsOf: bulk.appendingPathComponent("manifest.jsonl"),
            encoding: .utf8
        ).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(String(lines[0]).contains("../../export-record"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: bulk.path)
                .filter { $0 != "manifest.jsonl" }.count,
            1
        )
    }

    func testTranscriptWriterFailureDoesNotExposeTranscriptInDiagnostic() {
        let transcript = "DUMMY-TRANSCRIPT-SECRET-9F71"
        let expected = NSError(
            domain: "ArchiveExporterTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Injected storage diagnostic 42"]
        )

        XCTAssertThrowsError(
            try writeTranscriptExport(transcript, to: URL(fileURLWithPath: "/unused")) { _, _ in
                throw expected
            }
        )
        let message = transcriptExportFailureMessage(for: expected)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("transcript"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("export"))
        XCTAssertFalse(message.contains(transcript))
    }
}
