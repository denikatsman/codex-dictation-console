import CryptoKit
import Darwin
import Foundation

/// A recoverable file/index update. The ready journal is written only after all
/// replacement bytes exist; candidates stay intact until the SQLite commit.
/// Callers hold the archive lock. Keeping this inside capture staging also
/// includes it in the existing permanent-deletion journal.
struct ArchiveCapturePublication {
    private struct Journal: Codable {
        let version: Int
        let record: ArchivedDictationRecord
        let previousManifest: RecordingManifest?
    }

    let layout: ArchiveLayout
    let store: ArchiveStore

    func prepare(record: ArchivedDictationRecord, manifest: RecordingManifest,
                 metadata: Data?, audio: URL?, in staging: URL) throws {
        let folder = staging.appendingPathComponent(".publication", isDirectory: true)
        let ready = folder.appendingPathComponent("ready.json")
        guard !FileManager.default.fileExists(atPath: ready.path) else {
            throw ArchiveError.invalidRecord("An unfinished capture update must be resumed first.")
        }
        // Without a ready marker, nothing has been published. Original staged
        // chunks and metadata remain available if preparation was interrupted.
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if let audio { try FileManager.default.copyItem(at: audio, to: folder.appendingPathComponent("audio.webm")) }
        if let metadata { try metadata.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic) }
        try JSONEncoder.archiveEncoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try synchronize(file)
        }
        // Default date encoding retains fractional seconds in the index record.
        let previous = try store.record(id: record.id).map { try store.audioManifest(for: $0, verifyAudio: false) }
        try JSONEncoder().encode(Journal(version: 1, record: record, previousManifest: previous)).write(to: ready, options: .atomic)
        try synchronize(ready)
        try synchronizeDirectory(folder)
        try synchronizeDirectory(staging)
    }

    @discardableResult
    func resume(in staging: URL, afterFile: ((String) throws -> Void)? = nil) throws -> Bool {
        let folder = staging.appendingPathComponent(".publication", isDirectory: true)
        let ready = folder.appendingPathComponent("ready.json")
        guard FileManager.default.fileExists(atPath: ready.path) else { return false }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: ready))
        let record = journal.record
        guard journal.version == 1,
              staging.standardizedFileURL == layout.stagingURL.appendingPathComponent(DictationCaptureEngine.sha256(Data(record.sourceKey.utf8))).standardizedFileURL,
              record.archiveFolderURL.standardizedFileURL == layout.recordingsURL.appendingPathComponent(DictationCaptureEngine.sha256(Data(record.id.utf8))).standardizedFileURL else {
            throw ArchiveError.unsafeArchivePath
        }
        guard try !store.isTombstoned(sourceKey: record.sourceKey, recordID: record.id) else { return false }
        let manifest = try JSONDecoder.archiveDecoder.decode(RecordingManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let candidateAudio = folder.appendingPathComponent("audio.webm")
        let audio = FileManager.default.fileExists(atPath: candidateAudio.path) ? candidateAudio : record.audioURL
        try verify(manifest: manifest, record: record, audio: audio,
                   metadata: folder.appendingPathComponent("metadata.json"))
        if let current = try store.record(id: record.id) {
            guard current.sourceKey == record.sourceKey,
                  current.updatedAt <= record.updatedAt else {
                throw ArchiveError.invalidRecord("A pending capture conflicts with a newer archive index. All files were preserved.")
            }
            if current.audioSHA256 != record.audioSHA256 || current.audioSizeBytes != record.audioSizeBytes {
                try verifyPreviousAudio(in: audio, matches: current, previous: journal.previousManifest, replacement: manifest)
            }
        }
        try FileManager.default.createDirectory(at: record.archiveFolderURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        for name in ["audio.webm", "metadata.json", "manifest.json"] {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try publishFile(candidate, to: record.archiveFolderURL.appendingPathComponent(name))
                try afterFile?(name)
            }
        }
        try synchronizeDirectory(record.archiveFolderURL)
        try synchronizeDirectory(layout.recordingsURL)
        try store.upsert(record)
        try afterFile?("index")
        try FileManager.default.removeItem(at: folder)
        try synchronizeDirectory(staging)
        return true
    }

    /// Older builds could publish a manifest and die before updating SQLite.
    /// Adopt only a newer, fully verified snapshot containing the indexed audio.
    func reconcileLegacyIndex(_ old: ArchivedDictationRecord) throws -> ArchivedDictationRecord {
        do { _ = try store.audioManifest(for: old, verifyAudio: false); return old }
        catch {
            let originalError = error
            guard let manifest = try? JSONDecoder.archiveDecoder.decode(RecordingManifest.self, from: Data(contentsOf: old.manifestURL)),
                  manifest.schemaVersion == 1, manifest.recordID == old.id, manifest.sourceKey == old.sourceKey,
                  manifest.updatedAt > old.updatedAt, manifest.capturedSizeBytes >= old.audioSizeBytes,
                  !old.isDeleted else { throw originalError }
            let metadataData = try Data(contentsOf: old.metadataURL)
            let metadata = try JSONDecoder().decode(SourceMetadata.self, from: metadataData)
            guard metadata.id == nil || metadata.id == old.id,
                  old.transcript.isEmpty || !(metadata.text ?? "").isEmpty else { throw originalError }
            let recovered = ArchivedDictationRecord(
                id: old.id, sourceKey: old.sourceKey,
                createdAt: metadata.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1_000) } ?? old.createdAt,
                durationSeconds: max(0, (metadata.durationMs ?? 0) / 1_000),
                status: manifest.sourceStatus, surface: DictationSurface(rawValue: metadata.surface ?? "") ?? .unknown,
                transcript: metadata.text ?? "", mimeType: manifest.mimeType,
                audioSizeBytes: manifest.capturedSizeBytes, expectedSizeBytes: manifest.expectedSizeBytes,
                archiveFolderURL: old.archiveFolderURL, audioSHA256: manifest.audioSHA256,
                metadataSHA256: manifest.metadataSHA256, isPartial: manifest.isPartial,
                firstCapturedAt: old.firstCapturedAt, updatedAt: manifest.updatedAt)
            try verify(manifest: manifest, record: recovered, audio: old.audioURL, metadata: old.metadataURL)
            try verifyPrefix(of: old.audioURL, matches: old)
            // Retain the previous indexed transcript/provenance before repairing
            // the index, including when its original metadata was overwritten.
            let history = old.archiveFolderURL.appendingPathComponent("Index History", isDirectory: true)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let previous = try JSONEncoder().encode(old)
            let snapshot = history.appendingPathComponent(DictationCaptureEngine.sha256(previous) + ".json")
            try previous.write(to: snapshot, options: .atomic)
            try synchronize(snapshot)
            try store.upsert(recovered)
            return recovered
        }
    }

    private func verify(manifest: RecordingManifest, record: ArchivedDictationRecord,
                        audio: URL, metadata: URL) throws {
        guard manifest.schemaVersion == 1, manifest.recordID == record.id, manifest.sourceKey == record.sourceKey,
              manifest.capturedSizeBytes == record.audioSizeBytes, manifest.chunkByteCount == record.audioSizeBytes,
              manifest.audioSHA256 == record.audioSHA256, manifest.metadataSHA256 == record.metadataSHA256,
              manifest.sourceStatus == record.status, manifest.isPartial == record.isPartial,
              manifest.expectedSizeBytes == record.expectedSizeBytes, manifest.mimeType == record.mimeType,
              Set(manifest.chunks.map(\.index)).count == manifest.chunks.count else {
            throw ArchiveError.invalidRecord("The pending capture manifest failed verification. All files were preserved.")
        }
        if let hash = record.metadataSHA256 {
            guard try DictationCaptureEngine.sha256(fileAt: metadata) == hash else {
                throw ArchiveError.invalidRecord("The pending capture metadata failed verification. All files were preserved.")
            }
        }
        if record.audioSizeBytes > 0 {
            guard let hash = record.audioSHA256,
                  try Int64(audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == record.audioSizeBytes,
                  try DictationCaptureEngine.sha256(fileAt: audio) == hash else {
                throw ArchiveError.invalidRecord("The pending capture audio failed verification. All files were preserved.")
            }
            let input = try FileHandle(forReadingFrom: audio)
            defer { try? input.close() }
            for chunk in manifest.chunks {
                var remaining = chunk.sizeBytes
                var digest = SHA256()
                while remaining > 0 {
                    guard let data = try input.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty else {
                        throw ArchiveError.invalidRecord("The pending capture has a truncated chunk.")
                    }
                    digest.update(data: data)
                    remaining -= Int64(data.count)
                }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == chunk.sha256 else {
                    throw ArchiveError.invalidRecord("The pending capture chunk failed verification. All files were preserved.")
                }
            }
        }
    }

    private func verifyPrefix(of audio: URL, matches old: ArchivedDictationRecord) throws {
        guard old.audioSizeBytes > 0 else { return }
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        var remaining = old.audioSizeBytes
        var digest = SHA256()
        while remaining > 0 {
            guard let data = try input.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty else {
                throw ArchiveError.invalidRecord("The capture update is missing previously indexed audio.")
            }
            digest.update(data: data)
            remaining -= Int64(data.count)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == old.audioSHA256 else {
            throw ArchiveError.invalidRecord("The capture update conflicts with previously indexed audio. All files were preserved.")
        }
    }

    private func verifyPreviousAudio(in audio: URL, matches old: ArchivedDictationRecord,
                                     previous: RecordingManifest?, replacement: RecordingManifest) throws {
        guard old.audioSizeBytes > 0 else { return }
        guard let previous, previous.recordID == old.id, previous.sourceKey == old.sourceKey,
              previous.audioSHA256 == old.audioSHA256, previous.chunkByteCount == old.audioSizeBytes else {
            throw ArchiveError.invalidRecord("The pending capture lacks proof of its previous audio. All files were preserved.")
        }
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        var digest = SHA256()
        for chunk in previous.chunks {
            guard let position = replacement.chunks.firstIndex(where: { $0.index == chunk.index }),
                  replacement.chunks[position].sizeBytes >= chunk.sizeBytes else {
                throw ArchiveError.invalidRecord("The capture update is missing previously indexed chunks.")
            }
            // An earlier chunk can grow after a later one was staged. Verify
            // the old concatenation at the new chunk offsets, not a flat prefix.
            let offset = replacement.chunks.prefix(position).reduce(Int64(0)) { $0 + $1.sizeBytes }
            try input.seek(toOffset: UInt64(offset))
            var remaining = chunk.sizeBytes
            while remaining > 0 {
                guard let data = try input.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty else {
                    throw ArchiveError.invalidRecord("The capture update has truncated previous audio.")
                }
                digest.update(data: data)
                remaining -= Int64(data.count)
            }
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == old.audioSHA256 else {
            throw ArchiveError.invalidRecord("The capture update conflicts with previously indexed audio. All files were preserved.")
        }
    }

    private func publishFile(_ candidate: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: candidate, to: temporary)
        try synchronize(temporary)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func synchronize(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
