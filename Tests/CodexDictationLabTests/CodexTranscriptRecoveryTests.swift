import Foundation
import XCTest
@testable import DictationArchiveCore

final class CodexTranscriptRecoveryTests: XCTestCase {
    func testCodexAttemptPreservesOriginalsAndPriorAttemptAndExportsProvenance() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture)
        let before = try snapshot(record)
        let auth = try writeAuth(fixture)
        let service = CodexTranscriptRecovery(store: fixture.store, authURL: auth) { request, body in
            XCTAssertEqual(request.url, CodexTranscriptRecovery.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
            let multipart = try String(contentsOf: body, encoding: .utf8)
            XCTAssertTrue(multipart.contains("name=\"file\"; filename=\"audio.webm\"\r\nContent-Type: audio/webm\r\n\r\noriginal audio"))
            XCTAssertTrue(multipart.contains("name=\"language\"\r\n\r\nru\r\n"))
            XCTAssertFalse(multipart.contains("fake-test-token"))
            XCTAssertFalse(multipart.contains("model="))
            return (Data(#"{"text":"Русская расшифровка","asset_pointer":"unused-remote-asset"}"#.utf8), Self.response(200, headers: ["x-oai-request-id": "request-test"]))
        }
        let result = try await service.recover(recordID: record.id, localeIdentifier: "ru_RU")
        XCTAssertEqual(result.text, "Русская расшифровка")
        XCTAssertEqual(result.engine, CodexTranscriptRecovery.engine)
        XCTAssertEqual(result.requestID, "request-test")
        XCTAssertEqual(result.serviceURL, CodexTranscriptRecovery.endpoint.absoluteString)
        let after = try snapshot(record)
        for (name, data) in before { XCTAssertEqual(after[name], data, name) }
        let attempts = try TranscriptRecoveryStore.read(from: record)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.text, result.text)
        XCTAssertEqual(attempts.first?.requestID, result.requestID)
        XCTAssertEqual(attempts.first?.serviceURL, result.serviceURL)
        XCTAssertEqual(try XCTUnwrap(attempts.first).createdAt.timeIntervalSince1970, result.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(attempts.last?.text, "Previous macOS attempt")
        XCTAssertEqual(try fixture.store.record(id: record.id)?.transcript, "Exact original")
        let exported = try ArchiveExporter(store: fixture.store).export(recordID: record.id, to: fixture.root.appendingPathComponent("Exports"))
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("transcript.txt"), encoding: .utf8), "Exact original")
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("recovered-transcript.txt"), encoding: .utf8), result.text)
    }

    func testServiceErrorsAndEmptyResponsesCannotReplaceEarlierAttempts() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture)
        let before = try snapshot(record)
        let auth = try writeAuth(fixture)
        for (status, json) in [(401, "secret-error"), (403, "secret-error"), (429, "secret-error"), (503, "secret-error"),
                               (200, "<html>not JSON</html>"), (200, #"{"text":"  "}"#)] {
            let service = CodexTranscriptRecovery(store: fixture.store, authURL: auth) { _, body in
                XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
                return (Data(json.utf8), Self.response(status))
            }
            do {
                _ = try await service.recover(recordID: record.id)
                XCTFail("Expected failure for \(status): \(json)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("secret-error"))
            }
            XCTAssertEqual(try snapshot(record), before)
        }
    }

    func testAutomaticLanguageOmitsHintAndCancellationAfterUploadCannotPublish() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture)
        let before = try snapshot(record)
        let auth = try writeAuth(fixture)
        let service = CodexTranscriptRecovery(store: fixture.store, authURL: auth) { _, body in
            XCTAssertFalse(try String(contentsOf: body, encoding: .utf8).contains("name=\"language\""))
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data(#"{"text":"Must not be saved"}"#.utf8), Self.response(200))
        }
        let operation = Task { try await service.recover(recordID: record.id) }
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try snapshot(record), before)
    }

    func testDeletionDuringUploadDoesNotRecreateRecording() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture)
        let auth = try writeAuth(fixture)
        let service = CodexTranscriptRecovery(store: fixture.store, authURL: auth) { _, _ in
            try fixture.store.softDelete(id: record.id)
            return (Data(#"{"text":"Must not be saved"}"#.utf8), Self.response(200))
        }
        do { _ = try await service.recover(recordID: record.id); XCTFail("Expected deleted-record failure") }
        catch { XCTAssertTrue(error is TranscriptRecoveryError) }
        XCTAssertTrue(try XCTUnwrap(fixture.store.record(id: record.id)).isDeleted)
        XCTAssertEqual(try TranscriptRecoveryStore.read(from: record).count, 1)
    }

    func testMissingAndAPIKeyAuthDoNotUpload() async throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture)
        let auth = fixture.root.appendingPathComponent("auth.json")
        for contents in [nil, #"{"auth_mode":"apikey","OPENAI_API_KEY":"fake-key"}"#] as [String?] {
            if let contents { try Data(contents.utf8).write(to: auth) }
            let service = CodexTranscriptRecovery(store: fixture.store, authURL: auth) { _, _ in
                XCTFail("Must not upload without a ChatGPT sign-in")
                return (Data(), Self.response(200))
            }
            do { _ = try await service.recover(recordID: record.id); XCTFail("Expected sign-in error") }
            catch { XCTAssertTrue(error is CodexTranscriptRecoveryError) }
        }
    }

    func testLegacyMacOSAttemptRemainsReadableWithoutRemoteFields() throws {
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture)
        let attempt = try XCTUnwrap(TranscriptRecoveryStore.read(from: record).first)
        XCTAssertEqual(attempt.engine, "Apple SpeechTranscriber (on-device)")
        XCTAssertNil(attempt.serviceURL)
        XCTAssertNil(attempt.requestID)
    }

    func testLiveCodexRecoveryWithExplicitSyntheticFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEX_RECOVERY_LIVE_AUDIO"] else {
            throw XCTSkip("Set CODEX_RECOVERY_LIVE_AUDIO to the neutral synthetic WebM fixture for a live upload.")
        }
        let fixture = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try prepare(fixture, audio: Data(contentsOf: URL(fileURLWithPath: path)))
        let before = try snapshot(record)
        let result = try await CodexTranscriptRecovery(store: fixture.store).recover(recordID: record.id)
        XCTAssertEqual(result.text, "The blue notebook is on the table. This recording was sent from a saved file.")
        XCTAssertEqual(result.localeIdentifier, "auto")
        XCTAssertEqual(try TranscriptRecoveryStore.read(from: record).count, 2)
        XCTAssertEqual(try fixture.store.record(id: record.id)?.transcript, "Exact original")
        let after = try snapshot(record)
        for (name, data) in before { XCTAssertEqual(after[name], data, name) }
        print("Live Codex recovery succeeded; request ID: \(result.requestID ?? "unavailable"). Original and prior attempt preserved.")
    }

    private func snapshot(_ record: ArchivedDictationRecord) throws -> [String: Data] {
        let folder = record.archiveFolderURL
        let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in entries where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(folder.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    private func prepare(_ fixture: CaptureFixture, audio: Data = Data("original audio".utf8)) throws -> ArchivedDictationRecord {
        _ = try fixture.makeSourceRecording(sourceKey: "one", id: "one", transcript: "Exact original", chunks: [audio])
        _ = try fixture.engine.scan()
        let record = try XCTUnwrap(fixture.store.record(id: "one"))
        try TranscriptRecoveryStore(store: fixture.store).save(RecoveredTranscript(recordID: record.id, audioSHA256: record.audioSHA256!,
            localeIdentifier: "en_US", text: "Previous macOS attempt", createdAt: Date(timeIntervalSince1970: 100)))
        return record
    }

    private func writeAuth(_ fixture: CaptureFixture) throws -> URL {
        let url = fixture.root.appendingPathComponent("auth.json")
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fake-test-token","account_id":"test-account"}}"#.utf8).write(to: url)
        return url
    }

    private static func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: CodexTranscriptRecovery.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
