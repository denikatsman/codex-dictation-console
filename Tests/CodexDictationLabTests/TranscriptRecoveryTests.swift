import Foundation
import XCTest
@testable import DictationArchiveCore

final class TranscriptRecoveryTests: XCTestCase {
    func testRecoveryPreservesExactSourceAndExportsDerivedTextSeparately() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(sourceKey: "cancelled", id: "one", transcript: "", chunks: [Data("saved audio".utf8)], status: "cancelled")
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "one"))
        let metadata = try Data(contentsOf: record.metadataURL)
        let manifest = try Data(contentsOf: record.manifestURL)
        let recoveryStore = TranscriptRecoveryStore(store: fixture.store)
        let first = RecoveredTranscript(recordID: record.id, audioSHA256: record.audioSHA256!, localeIdentifier: "en_US", text: "Recovered words", createdAt: Date(timeIntervalSince1970: 100))
        let second = RecoveredTranscript(recordID: record.id, audioSHA256: record.audioSHA256!, localeIdentifier: "ru_RU", text: "Повторная расшифровка", createdAt: Date(timeIntervalSince1970: 101), engine: "Apple DictationTranscriber (on-device)")
        let firstURL = try recoveryStore.save(first)
        _ = try recoveryStore.save(second)
        XCTAssertEqual(try TranscriptRecoveryStore.read(from: record), [second, first])
        XCTAssertEqual(try TranscriptRecoveryStore.read(from: record).first?.engine, "Apple DictationTranscriber (on-device)")
        XCTAssertEqual(try fixture.store.record(id: "one")?.transcript, "")
        XCTAssertEqual(try Data(contentsOf: record.metadataURL), metadata)
        XCTAssertEqual(try Data(contentsOf: record.manifestURL), manifest)
        XCTAssertEqual(try fixture.store.record(id: "one")?.status, "cancelled")
        let export = try ArchiveExporter(store: fixture.store).export(recordID: "one", to: fixture.root.appendingPathComponent("Exports"))
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("transcript.txt"), encoding: .utf8), "")
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("recovered-transcript.txt"), encoding: .utf8), second.text)
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent(TranscriptRecoveryStore.directoryName).appendingPathComponent(firstURL.lastPathComponent)), try Data(contentsOf: firstURL))
        XCTAssertEqual(record.partialCaptureTitle, "Source recording cancelled")
        XCTAssertTrue(record.partialCaptureExplanation.contains("All reported audio bytes"))
    }

    func testChangedAudioAndDeletionDuringRecognitionCannotPublishTextOrRecreateRecord() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(sourceKey: "source", id: "one", transcript: "", chunks: [Data("audio".utf8)])
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "one"))
        let recoveryStore = TranscriptRecoveryStore(store: fixture.store)
        let recovery = RecoveredTranscript(recordID: "one", audioSHA256: record.audioSHA256!, localeIdentifier: "en_US", text: "Words")
        let snapshot = fixture.root.appendingPathComponent("snapshot.webm")
        _ = try recoveryStore.copyAudio(recordID: "one", to: snapshot)
        XCTAssertEqual(try Data(contentsOf: snapshot), Data("audio".utf8))
        try Data("changed".utf8).write(to: record.audioURL, options: .atomic)
        XCTAssertThrowsError(try recoveryStore.save(recovery))
        try Data("audio".utf8).write(to: record.audioURL, options: .atomic)
        try fixture.store.softDelete(id: "one")
        XCTAssertThrowsError(try recoveryStore.save(recovery))
        XCTAssertTrue(try TranscriptRecoveryStore.read(from: record).isEmpty)
    }

    func testEmptyAndMismatchedRecoveryAreRejectedWithoutOverwritingSavedRecovery() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.makeSourceRecording(sourceKey: "source", id: "one", transcript: "", chunks: [Data("audio".utf8)])
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "one"))
        let store = TranscriptRecoveryStore(store: fixture.store)
        XCTAssertThrowsError(try store.save(RecoveredTranscript(recordID: "one", audioSHA256: record.audioSHA256!, localeIdentifier: "en_US", text: " \n ")))
        let url = try store.save(RecoveredTranscript(recordID: "one", audioSHA256: record.audioSHA256!, localeIdentifier: "en_US", text: "Saved words"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["audioSHA256"] = "different recording"
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        XCTAssertThrowsError(try TranscriptRecoveryStore.read(from: record))
        let destination = fixture.root.appendingPathComponent("Exports")
        XCTAssertThrowsError(try ArchiveExporter(store: fixture.store).export(recordID: "one", to: destination))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertTrue(try fixture.store.verifyArchivedFiles().issues.contains { $0.message.contains("Recovered transcripts") })
    }
}
