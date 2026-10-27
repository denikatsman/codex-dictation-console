import Foundation

public enum CodexTranscriptRecoveryError: LocalizedError {
    case signInRequired, accessDenied, rateLimited, failed(Int), invalidResponse

    public var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Open Codex and sign in with ChatGPT, then retry. This option needs a current ChatGPT sign-in on this Mac."
        case .accessDenied:
            "Codex transcription is not available for the current sign-in (HTTP 403). Your audio and previous attempts are preserved."
        case .rateLimited:
            "Codex transcription is temporarily rate limited. Please try again later."
        case .failed(let status):
            "Codex transcription failed (HTTP \(status)). Your audio and previous attempts are preserved."
        case .invalidResponse:
            "Codex returned an unreadable transcription response. Your audio and previous attempts are preserved."
        }
    }
}

/// Uses the private route observed in Codex Desktop. Only an explicit recovery
/// action uploads audio; credentials stay in memory and never enter the archive.
public struct CodexTranscriptRecovery: Sendable {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    public static let engine = "Codex transcription (OpenAI)"
    typealias Upload = @Sendable (URLRequest, URL) async throws -> (Data, HTTPURLResponse)
    private let store: ArchiveStore
    private let authURL: URL
    private let upload: Upload

    public init(store: ArchiveStore = ArchiveStore()) {
        self.init(store: store,
                  authURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"),
                  upload: { try await Self.performUpload($0, file: $1) })
    }

    init(store: ArchiveStore, authURL: URL, upload: @escaping Upload) {
        self.store = store
        self.authURL = authURL
        self.upload = upload
    }

    @discardableResult
    public func recover(recordID: String, localeIdentifier: String = "auto",
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> RecoveredTranscript {
        try Task.checkCancellation()
        let auth = try Self.authentication(at: authURL)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CodexRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let recoveryStore = TranscriptRecoveryStore(store: store)
        let audio = scratch.appendingPathComponent("audio.webm")
        await progress("Preparing saved audio…")
        let record = try await Task.detached {
            try recoveryStore.copyAudio(recordID: recordID, to: audio)
        }.value
        try Task.checkCancellation()
        let boundary = "----codex-transcribe-" + UUID().uuidString
        let body = scratch.appendingPathComponent("upload.multipart")
        let language = localeIdentifier == "auto" ? nil : Locale(identifier: localeIdentifier).language.languageCode?.identifier
        let preparation = Task.detached {
            try Self.writeMultipart(audio: audio, destination: body, boundary: boundary, language: language)
        }
        try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
        if let account = auth.accountID { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        let version = CodexApplicationLocator.locate().flatMap { CodexApplicationLocator.information(at: $0)?["CFBundleShortVersionString"] as? String } ?? "unknown"
        request.setValue("Codex Desktop/\(version) (Mac OS; arm64)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        await progress("Uploading saved audio to OpenAI and transcribing with Codex…")
        // No automatic retry: the user decides whether to upload another attempt.
        let (data, response) = try await upload(request, body)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200..<300: break
        case 401: throw CodexTranscriptRecoveryError.signInRequired
        case 403: throw CodexTranscriptRecoveryError.accessDenied
        case 429: throw CodexTranscriptRecoveryError.rateLimited
        default: throw CodexTranscriptRecoveryError.failed(response.statusCode)
        }
        struct Response: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CodexTranscriptRecoveryError.invalidResponse
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptRecoveryError.emptyTranscript
        }
        let recovery = RecoveredTranscript(recordID: record.id, audioSHA256: record.audioSHA256!,
            localeIdentifier: localeIdentifier, text: result.text, engine: Self.engine,
            serviceURL: Self.endpoint.absoluteString,
            requestID: response.value(forHTTPHeaderField: "x-oai-request-id") ?? response.value(forHTTPHeaderField: "x-request-id"))
        await progress("Saving recovered transcript…")
        try Task.checkCancellation()
        _ = try await Task.detached { try recoveryStore.save(recovery) }.value
        return recovery
    }

    private static func authentication(at url: URL) throws -> (token: String, accountID: String?) {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String; let account_id: String? }
            let auth_mode: String?
            let tokens: Tokens?
        }
        guard let data = try? Data(contentsOf: url), let auth = try? JSONDecoder().decode(Auth.self, from: data),
              auth.auth_mode == nil || auth.auth_mode == "chatgpt",
              let tokens = auth.tokens, !tokens.access_token.isEmpty,
              !tokens.access_token.contains(where: { $0.isNewline }),
              tokens.account_id?.contains(where: { $0.isNewline }) != true else {
            throw CodexTranscriptRecoveryError.signInRequired
        }
        return (tokens.access_token, tokens.account_id)
    }

    private static func writeMultipart(audio: URL, destination: URL, boundary: String, language: String?) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.webm\"\r\nContent-Type: audio/webm\r\n\r\n".utf8))
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        if let language {
            try output.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)".utf8))
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private static func performUpload(_ request: URLRequest, file: URL) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRecoveryRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let response = response as? HTTPURLResponse else { throw CodexTranscriptRecoveryError.invalidResponse }
        return (data, response)
    }
}

private final class NoRecoveryRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
