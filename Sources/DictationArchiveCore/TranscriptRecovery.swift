import AVFoundation
import Foundation
import Speech

public struct RecoveredTranscript: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordID: String
    public let audioSHA256: String
    public let engine: String
    public let localeIdentifier: String
    public let createdAt: Date
    public let text: String
    public let serviceURL: String?
    public let requestID: String?

    public init(recordID: String, audioSHA256: String, localeIdentifier: String, text: String, createdAt: Date = Date(),
                engine: String = "Apple SpeechTranscriber (on-device)", serviceURL: String? = nil, requestID: String? = nil) {
        schemaVersion = 1
        self.recordID = recordID
        self.audioSHA256 = audioSHA256
        self.engine = engine
        self.localeIdentifier = localeIdentifier
        self.createdAt = createdAt
        self.text = text
        self.serviceURL = serviceURL
        self.requestID = requestID
    }
}

public enum TranscriptRecoveryError: LocalizedError {
    case unavailable, unsupportedLocale, emptyTranscript, audioChanged, invalidRecovery

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Local transcript recovery requires macOS 26 or later and a supported Apple speech model."
        case .unsupportedLocale: "Apple's local speech model does not support this language on this Mac."
        case .emptyTranscript: "Transcription returned no words. The saved audio and previous attempts are still available."
        case .audioChanged: "The archived audio changed or the recording was deleted. Recovery was stopped; the original files were preserved."
        case .invalidRecovery: "A recovered transcript could not be verified against this recording."
        }
    }
}

/// Derived text has independent provenance. Never put it in Codex's exact
/// transcript, metadata, manifest, or source folder.
public struct TranscriptRecoveryStore: Sendable {
    public static let directoryName = "Recovered Transcripts"
    private let store: ArchiveStore

    public init(store: ArchiveStore = ArchiveStore()) { self.store = store }

    public static func read(from record: ArchivedDictationRecord) throws -> [RecoveredTranscript] {
        let directory = record.archiveFolderURL.appendingPathComponent(directoryName)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let item = try decoder.decode(RecoveredTranscript.self, from: Data(contentsOf: url))
                guard item.schemaVersion == 1, item.recordID == record.id,
                      item.audioSHA256 == record.audioSHA256,
                      !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranscriptRecoveryError.invalidRecovery
                }
                return item
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func save(_ recovery: RecoveredTranscript) throws -> URL {
        try ArchiveLock.withExclusiveAccess(to: store.layout) {
            guard let current = try store.record(id: recovery.recordID), !current.isDeleted,
                  current.status != "recording", current.audioSHA256 == recovery.audioSHA256,
                  try DictationCaptureEngine.sha256(fileAt: current.audioURL) == recovery.audioSHA256 else {
                throw TranscriptRecoveryError.audioChanged
            }
            guard !recovery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptRecoveryError.emptyTranscript
            }
            let directory = current.archiveFolderURL.appendingPathComponent(Self.directoryName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let output = directory.appendingPathComponent(UUID().uuidString + ".json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(recovery).write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return output
        }
    }

    /// Capture a checksum-verified snapshot under the archive lock, then release
    /// the lock before any model work or asset download.
    public func copyAudio(recordID: String, to destination: URL) throws -> ArchivedDictationRecord {
        try ArchiveLock.withExclusiveAccess(to: store.layout) {
            guard let record = try store.record(id: recordID), !record.isDeleted,
                  record.status != "recording", let hash = record.audioSHA256,
                  try DictationCaptureEngine.sha256(fileAt: record.audioURL) == hash else {
                throw TranscriptRecoveryError.audioChanged
            }
            try FileManager.default.copyItem(at: record.audioURL, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return record
        }
    }
}

public struct LocalTranscriptRecovery: Sendable {
    private let store: ArchiveStore
    public init(store: ArchiveStore = ArchiveStore()) { self.store = store }

    public static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    public static func supportedLocales() async -> [Locale] {
        if #available(macOS 26, *) {
            let primary = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
            let fallback = await DictationTranscriber.supportedLocales
            return Array(Set(primary + fallback))
        }
        return []
    }

    @discardableResult
    public func recover(recordID: String, locale: Locale,
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> RecoveredTranscript {
        guard #available(macOS 26, *) else {
            throw TranscriptRecoveryError.unavailable
        }
        try Task.checkCancellation()
        let primaryLocale = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocale(equivalentTo: locale) : nil
        let fallbackLocale = primaryLocale == nil ? await DictationTranscriber.supportedLocale(equivalentTo: locale) : nil
        guard let locale = primaryLocale ?? fallbackLocale else {
            throw TranscriptRecoveryError.unsupportedLocale
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DictationRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let recoveryStore = TranscriptRecoveryStore(store: store)
        let source = scratch.appendingPathComponent("audio.webm")
        let record = try await Task.detached {
            try recoveryStore.copyAudio(recordID: recordID, to: source)
        }.value
        try Task.checkCancellation()
        await progress("Preparing saved audio…")
        let audio = scratch.appendingPathComponent("audio.m4a")
        let conversion = Task.detached {
            try NativePlaybackAudioConverter().convert(sourceURL: source, destinationURL: audio)
        }
        _ = try await withTaskCancellationHandler { try await conversion.value } onCancel: { conversion.cancel() }
        try Task.checkCancellation()
        let transcriber: any SpeechModule
        let engine: String
        let readResults: @Sendable () async throws -> String
        if primaryLocale != nil {
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            transcriber = module
            engine = "Apple SpeechTranscriber (on-device)"
            readResults = {
                var text = ""
                for try await result in module.results {
                    try Task.checkCancellation()
                    text += String(result.text.characters)
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            let module = DictationTranscriber(locale: locale, preset: .longDictation)
            transcriber = module
            engine = "Apple DictationTranscriber (on-device)"
            readResults = {
                var text = ""
                for try await result in module.results {
                    try Task.checkCancellation()
                    text += String(result.text.characters)
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Reservations belong to the current application. Release only a
        // reservation this operation acquired, including on failure.
        let reserved = try await AssetInventory.reserve(locale: locale)
        do {
            await progress("Preparing Apple's local speech model…")
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                await progress("Downloading Apple's speech model; your audio stays on this Mac…")
                try await installation.downloadAndInstall()
            }
            try Task.checkCancellation()
            await progress("Transcribing on this Mac…")
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            // Both presets emit finalized results only.
            let results = Task { try await readResults() }
            let text: String
            do {
                text = try await withTaskCancellationHandler {
                    try await analyzer.start(inputAudioFile: AVAudioFile(forReading: audio), finishAfterFile: true)
                    return try await results.value
                } onCancel: {
                    results.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                }
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            try Task.checkCancellation()
            guard !text.isEmpty else { throw TranscriptRecoveryError.emptyTranscript }
            let recovery = RecoveredTranscript(recordID: record.id, audioSHA256: record.audioSHA256!,
                                               localeIdentifier: locale.identifier, text: text, engine: engine)
            await progress("Saving recovered transcript…")
            _ = try await Task.detached { try recoveryStore.save(recovery) }.value
            if reserved { await AssetInventory.release(reservedLocale: locale) }
            return recovery
        } catch {
            if reserved { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }
}
