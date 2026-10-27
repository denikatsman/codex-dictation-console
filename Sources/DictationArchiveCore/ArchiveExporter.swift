import Foundation

public struct ArchiveExporter: Sendable {
    private let store: ArchiveStore

    public init(store: ArchiveStore = ArchiveStore()) {
        self.store = store
    }

    @discardableResult
    public func export(recordID: String, to destinationDirectory: URL) throws -> URL {
        try ArchiveLock.withExclusiveAccess(to: store.layout) {
            guard let record = try store.record(id: recordID) else {
                throw ArchiveError.missingRecord
            }
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            let folder = uniqueDestination(
                in: destinationDirectory,
                preferredName: exportFolderName(for: record)
            )
            try export(record: record, toExactDirectory: folder)
            return folder
        }
    }

    @discardableResult
    public func exportAll(to destinationDirectory: URL, now: Date = Date()) throws -> URL {
        try ArchiveLock.withExclusiveAccess(to: store.layout) {
            let records = try store.records()
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let root = uniqueDestination(
                in: destinationDirectory,
                preferredName: "Codex Dictation Archive \(formatter.string(from: now))"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

            var manifestLines = Data()
            let lineEncoder = JSONEncoder()
            lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            lineEncoder.dateEncodingStrategy = .iso8601
            do {
                for record in records {
                    let recordFolder = uniqueDestination(
                        in: root,
                        preferredName: exportFolderName(for: record)
                    )
                    try export(record: record, toExactDirectory: recordFolder)
                    let item = BulkManifestItem(
                        record: record,
                        folderName: recordFolder.lastPathComponent
                    )
                    var data = try lineEncoder.encode(item)
                    data.append(0x0A)
                    manifestLines.append(data)
                }
                try manifestLines.write(
                    to: root.appendingPathComponent("manifest.jsonl"),
                    options: .atomic
                )
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            return root
        }
    }

    private func export(
        record: ArchivedDictationRecord,
        toExactDirectory destination: URL
    ) throws {
        let fileManager = FileManager.default
        let manifest = try store.audioManifest(for: record)
        guard manifest.metadataSHA256 == record.metadataSHA256 else {
            throw ArchiveError.invalidRecord("The metadata manifest disagrees with the index; export was stopped.")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let recovered = try TranscriptRecoveryStore.read(from: record)
            try writeTranscriptExport(
                record.transcript,
                to: destination.appendingPathComponent("transcript.txt")
            )
            if let latest = recovered.first {
                try writeTranscriptExport(latest.text, to: destination.appendingPathComponent("recovered-transcript.txt"))
            }
            for filename in ["audio.webm", "metadata.json", "manifest.json", "Metadata History", TranscriptRecoveryStore.directoryName] {
                let source = record.archiveFolderURL.appendingPathComponent(filename)
                let required = filename == "manifest.json"
                    || (filename == "audio.webm" && record.audioSizeBytes > 0)
                    || (filename == "metadata.json" && record.metadataSHA256 != nil)
                guard fileManager.fileExists(atPath: source.path) else {
                    if required { throw ArchiveError.invalidRecord("Required export file \(filename) is missing.") }
                    continue
                }
                let target = destination.appendingPathComponent(filename)
                try fileManager.copyItem(
                    at: source,
                    to: target
                )
                let expectedHash = filename == "audio.webm" ? record.audioSHA256
                    : filename == "metadata.json" ? record.metadataSHA256 : nil
                if let expectedHash, try DictationCaptureEngine.sha256(fileAt: target) != expectedHash {
                    throw ArchiveError.invalidRecord("Exported \(filename) failed its checksum check.")
                }
                if filename == "Metadata History" {
                    for snapshot in try fileManager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
                        let hash = try DictationCaptureEngine.sha256(fileAt: snapshot)
                        guard snapshot.lastPathComponent == hash + ".json" else {
                            throw ArchiveError.invalidRecord("An exported Metadata History snapshot failed its checksum check.")
                        }
                    }
                }
                if filename == TranscriptRecoveryStore.directoryName {
                    for snapshot in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                        let copied = target.appendingPathComponent(snapshot.lastPathComponent)
                        guard try DictationCaptureEngine.sha256(fileAt: copied) == DictationCaptureEngine.sha256(fileAt: snapshot) else {
                            throw ArchiveError.invalidRecord("An exported recovered transcript failed its checksum check.")
                        }
                    }
                }
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func uniqueDestination(in parent: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        var candidate = parent.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(preferredName) (\(suffix))",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    private func exportFolderName(for record: ArchivedDictationRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeIdentifier = DictationCaptureEngine.sha256(Data(record.id.utf8)).prefix(8)
        return "\(formatter.string(from: record.createdAt)) - \(safeIdentifier)"
    }
}

public typealias TranscriptExportWriter = (Data, URL) throws -> Void

public func writeTranscriptExport(
    _ text: String,
    to url: URL,
    using writer: TranscriptExportWriter = { data, url in
        try data.write(to: url, options: .atomic)
    }
) throws {
    guard let data = text.data(using: .utf8) else {
        throw ArchiveError.invalidRecord("The transcript could not be encoded as UTF-8.")
    }
    try writer(data, url)
}

public func transcriptExportFailureMessage(for error: Error) -> String {
    "The transcript could not be exported. \(error.localizedDescription)"
}

private struct BulkManifestItem: Encodable {
    let id: String
    let sourceKey: String
    let createdAt: Date
    let durationSeconds: Double
    let status: String
    let surface: String
    let transcript: String
    let mimeType: String?
    let audioSizeBytes: Int64
    let expectedSizeBytes: Int64?
    let audioSHA256: String?
    let metadataSHA256: String?
    let isPartial: Bool
    let folder: String

    init(record: ArchivedDictationRecord, folderName: String) {
        id = record.id
        sourceKey = record.sourceKey
        createdAt = record.createdAt
        durationSeconds = record.durationSeconds
        status = record.status
        surface = record.surface.rawValue
        transcript = record.transcript
        mimeType = record.mimeType
        audioSizeBytes = record.audioSizeBytes
        expectedSizeBytes = record.expectedSizeBytes
        audioSHA256 = record.audioSHA256
        metadataSHA256 = record.metadataSHA256
        isPartial = record.isPartial
        folder = folderName
    }
}
