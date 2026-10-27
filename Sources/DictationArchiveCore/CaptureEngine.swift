import CryptoKit
import Foundation

public struct DictationCaptureEngine: Sendable {
    public let sourceURL: URL
    public let layout: ArchiveLayout
    public let processKind: CaptureProcessKind

    private let store: ArchiveStore
    private let settingsStore: CaptureSettingsStore
    private let statusStore: CaptureStatusStore

    private var publication: ArchiveCapturePublication { ArchiveCapturePublication(layout: layout, store: store) }

    public init(
        sourceURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/dictation-history", isDirectory: true),
        layout: ArchiveLayout = ArchiveLayout(),
        processKind: CaptureProcessKind = .manual
    ) {
        self.sourceURL = sourceURL
        self.layout = layout
        self.processKind = processKind
        store = ArchiveStore(layout: layout)
        settingsStore = CaptureSettingsStore(layout: layout)
        statusStore = CaptureStatusStore(layout: layout)
    }

    @discardableResult
    public func scan(now: Date = Date()) throws -> CaptureScanResult {
        do {
            return try ArchiveLock.withExclusiveAccess(to: layout) {
                try autoreleasepool { try scanWithExclusiveAccess(now: now) }
            }
        } catch {
            // Do not leave yesterday's healthy heartbeat after a database or
            // directory failure. This path deliberately does not read the DB.
            let previous = statusStore.load()
            let settings = settingsStore.load()
            try? statusStore.save(CaptureHealthSnapshot(
                process: processKind, processID: getpid(),
                captureEnabled: settings.captureEnabled, isPaused: settings.isPaused,
                sourceAvailable: FileManager.default.fileExists(atPath: sourceURL.path),
                sourceRecordCount: previous?.sourceRecordCount ?? 0,
                archiveRecordCount: previous?.archiveRecordCount ?? 0,
                lastScanAt: now, lastCaptureAt: previous?.lastCaptureAt,
                lastError: error.localizedDescription
            ))
            throw error
        }
    }

    private func scanWithExclusiveAccess(now: Date) throws -> CaptureScanResult {
        try store.prepare()
        let deletionErrors = try store.resumeDeletionsWithExclusiveAccess()
        let settings = try settingsStore.loadChecked()
        let sourceAvailable = FileManager.default.fileExists(atPath: sourceURL.path)
        let sourceFolders = sourceAvailable ? try recordingFolders(at: sourceURL) : []

        guard settings.captureEnabled, !settings.isPaused else {
            let result = CaptureScanResult(
                sourceRecordCount: sourceFolders.count,
                importedCount: 0,
                updatedCount: 0,
                skippedTombstoneCount: 0,
                errors: deletionErrors,
                completedAt: now
            )
            try saveHealth(
                result: result,
                settings: settings,
                sourceAvailable: sourceAvailable,
                now: now
            )
            return result
        }

        var imported = 0
        var updated = 0
        var skipped = 0
        var errors: [String] = deletionErrors
        var currentSourceKeys = Set<String>()

        for folder in sourceFolders {
            let sourceKey = folder.lastPathComponent
            currentSourceKeys.insert(sourceKey)
            do {
                switch try capture(folder: folder, now: now, errors: &errors) {
                case .imported: imported += 1
                case .updated: updated += 1
                case .skippedTombstone: skipped += 1
                case .unchanged, .stagedOnly: break
                }
            } catch {
                errors.append("\(sourceKey.prefix(12)): \(error.localizedDescription)")
            }
        }

        for stagingFolder in try recordingFolders(at: layout.stagingURL) {
            do {
                let info = try loadStagingInfo(from: stagingFolder)
                guard !currentSourceKeys.contains(info.sourceKey) else { continue }
                if try store.isTombstoned(sourceKey: info.sourceKey) {
                    // Soft deletion is reversible. Only the permanent-deletion
                    // journal may remove staged audio or metadata history.
                    skipped += 1
                    continue
                }
                switch try finalize(stagingFolder: stagingFolder, now: now) {
                case .imported: imported += 1
                case .updated: updated += 1
                case .unchanged, .stagedOnly, .skippedTombstone: break
                }
            } catch {
                errors.append("staging \(stagingFolder.lastPathComponent.prefix(12)): \(error.localizedDescription)")
            }
        }

        let result = CaptureScanResult(
            sourceRecordCount: sourceFolders.count,
            importedCount: imported,
            updatedCount: updated,
            skippedTombstoneCount: skipped,
            errors: errors,
            completedAt: now
        )
        try saveHealth(
            result: result,
            settings: settings,
            sourceAvailable: sourceAvailable,
            now: now
        )
        return result
    }

    private func capture(folder: URL, now: Date, errors: inout [String]) throws -> CaptureDisposition {
        let sourceKey = folder.lastPathComponent
        var existing = try store.record(sourceKey: sourceKey)
        let claimedID = (try? Data(contentsOf: folder.appendingPathComponent("metadata.json")))
            .flatMap { try? JSONDecoder().decode(SourceMetadata.self, from: $0).id }
        if try store.isTombstoned(sourceKey: sourceKey, recordID: existing?.id ?? claimedID) {
            return .skippedTombstone
        }
        let stagingFolder = layout.stagingURL
            .appendingPathComponent(Self.sha256(Data(sourceKey.utf8)), isDirectory: true)
        try publication.resume(in: stagingFolder)
        existing = try store.record(sourceKey: sourceKey).map { try publication.reconcileLegacyIndex($0) }
        if existing == nil, let claimedID, let owner = try store.record(id: claimedID), owner.sourceKey != sourceKey {
            errors.append("\(sourceKey.prefix(12)): The source reused another recording's ID. This recording will receive a separate stable archive ID.")
        }

        let chunksFolder = stagingFolder.appendingPathComponent("Chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksFolder, withIntermediateDirectories: true)
        try writeStagingInfo(StagingInfo(sourceKey: sourceKey), to: stagingFolder)

        let sourceMetadataURL = folder.appendingPathComponent("metadata.json")
        var sourceMetadataData: Data?
        var sourceMetadata: SourceMetadata?
        if let data = try? Data(contentsOf: sourceMetadataURL) {
            sourceMetadataData = data
            do {
                sourceMetadata = try JSONDecoder().decode(SourceMetadata.self, from: data)
                errors.append(contentsOf: (sourceMetadata?.compatibilityIssues ?? []).map {
                    "\(sourceKey.prefix(12)): Codex recording format: \($0). Available text and audio are being retained."
                })
            } catch {
                try preserveMetadata(data, in: stagingFolder)
                errors.append("\(sourceKey.prefix(12)): Codex metadata could not be decoded. The original bytes are retained for recovery.")
            }
        } else if FileManager.default.fileExists(atPath: sourceMetadataURL.path) {
            errors.append("\(sourceKey.prefix(12)): Codex metadata could not be read. Capture will retry.")
        }

        let stagedMetadataURL = stagingFolder.appendingPathComponent("metadata.json")
        let stagedData = try? Data(contentsOf: stagedMetadataURL)
        let archivedData = try existing.map { record -> Data? in
            guard record.metadataSHA256 != nil else { return nil }
            // A read failure must not allow us to overwrite the only saved copy.
            return try Data(contentsOf: record.metadataURL)
        } ?? nil
        let priorData = [stagedData, archivedData].compactMap { $0 }.first(where: Self.hasTranscript)
        // Save each text-bearing source version before any audio operation.
        // Empty or malformed later metadata must never erase known words.
        for data in [priorData, sourceMetadataData].compactMap({ $0 }) where Self.hasTranscript(data) {
            try preserveMetadata(data, in: stagingFolder)
        }
        if let priorData, sourceMetadataData.map(Self.hasTranscript) != true {
            if let sourceMetadataData { try preserveMetadata(sourceMetadataData, in: stagingFolder) }
            sourceMetadataData = priorData
            sourceMetadata = try JSONDecoder().decode(SourceMetadata.self, from: priorData)
        } else if sourceMetadata == nil, let stagedData,
                  let stagedMetadata = try? JSONDecoder().decode(SourceMetadata.self, from: stagedData) {
            // Even an audio-only but valid snapshot is better than a torn write.
            sourceMetadataData = stagedData
            sourceMetadata = stagedMetadata
        } else if sourceMetadata == nil, let archivedData {
            sourceMetadataData = archivedData
            sourceMetadata = try JSONDecoder().decode(SourceMetadata.self, from: archivedData)
        }

        // Persist the retry input BEFORE changing canonical archive files/index.
        if let sourceMetadataData, sourceMetadataData != stagedData {
            try sourceMetadataData.write(to: stagedMetadataURL, options: .atomic)
        }
        if let metadata = sourceMetadata,
           let existing,
           canUpdateMetadataOnly(existing: existing, metadata: metadata) {
            guard let sourceMetadataData else { return .unchanged }
            try mergeMetadataHistory(from: stagingFolder, into: existing.archiveFolderURL)
            let disposition = try updateMetadataOnly(
                existing: existing,
                metadata: metadata,
                metadataData: sourceMetadataData,
                now: now
            )
            try? FileManager.default.removeItem(at: stagingFolder)
            return disposition
        }

        var allChunksWereStable = true
        do {
            for sourceChunk in try chunkFiles(at: folder) {
                let destination = chunksFolder.appendingPathComponent(sourceChunk.lastPathComponent)
                do {
                    if try !copyStableFileIfNeeded(from: sourceChunk, to: destination) {
                        allChunksWereStable = false
                    }
                } catch {
                    allChunksWereStable = false
                    errors.append("\(sourceKey.prefix(12)): audio capture: \(error.localizedDescription)")
                }
            }
        } catch {
            allChunksWereStable = false
            errors.append("\(sourceKey.prefix(12)): audio listing: \(error.localizedDescription)")
        }

        guard sourceMetadata != nil else { return .stagedOnly }
        // Publish the recoverable text even if audio needs another scan.
        return try finalize(stagingFolder: stagingFolder, now: now, forcePartial: !allChunksWereStable)
    }

    private func finalize(stagingFolder: URL, now: Date, forcePartial: Bool = false) throws -> CaptureDisposition {
        let info = try loadStagingInfo(from: stagingFolder)
        if try store.isTombstoned(sourceKey: info.sourceKey) {
            return .skippedTombstone
        }
        try publication.resume(in: stagingFolder)
        let metadataURL = stagingFolder.appendingPathComponent("metadata.json")
        var metadataData = try? Data(contentsOf: metadataURL)
        var recoveredHistoryOnly = false
        let existing = try store.record(sourceKey: info.sourceKey).map { try publication.reconcileLegacyIndex($0) }
        if metadataData == nil, existing == nil {
            let history = stagingFolder.appendingPathComponent("Metadata History")
            if FileManager.default.fileExists(atPath: history.path) {
                let snapshots = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
                guard snapshots.count <= 1 else {
                    throw ArchiveError.invalidRecord("Multiple historical metadata snapshots have no canonical version. They were preserved for inspection.")
                }
                if let snapshot = snapshots.first {
                    let data = try Data(contentsOf: snapshot)
                    guard snapshot.lastPathComponent == Self.sha256(data) + ".json" else {
                        throw ArchiveError.invalidRecord("A metadata history checksum does not match.")
                    }
                    metadataData = data
                    recoveredHistoryOnly = true
                }
            }
        }
        var decodedMetadata = metadataData.flatMap {
            try? JSONDecoder().decode(SourceMetadata.self, from: $0)
        }
        if decodedMetadata == nil, let existing,
           let previousData = try? Data(contentsOf: existing.metadataURL),
           let previous = try? JSONDecoder().decode(SourceMetadata.self, from: previousData) {
            if let metadataData { try preserveMetadata(metadataData, in: stagingFolder) }
            metadataData = previousData
            decodedMetadata = previous
        }
        if decodedMetadata == nil, existing?.isPartial == false {
            // Source cleanup can briefly expose a formerly complete folder
            // without usable metadata. Never replace already archived
            // transcript and provenance with an empty orphan record. Partial
            // orphans must keep their staged chunks for future recovery.
            try? FileManager.default.removeItem(at: stagingFolder)
            return .unchanged
        }
        let metadata = decodedMetadata ?? SourceMetadata(
            createdAtMs: nil,
            durationMs: nil,
            id: nil,
            mimeType: nil,
            sizeBytes: nil,
            status: nil,
            surface: nil,
            text: nil
        )
        // Once an audio-only orphan has been archived, keep its provisional ID
        // stable if the source folder later reappears with terminal metadata.
        // Changing the ID here would collide with the source_key uniqueness
        // constraint and strand the recoverable recording in staging.
        let recordID = try store.resolvedRecordID(sourceKey: info.sourceKey, metadataID: metadata.id)
        if try store.isTombstoned(sourceKey: info.sourceKey, recordID: existing?.id ?? metadata.id) {
            return .skippedTombstone
        }
        let recordFolder = layout.recordingsURL
            .appendingPathComponent(Self.sha256(Data(recordID.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: recordFolder, withIntermediateDirectories: true)
        try mergeMetadataHistory(from: stagingFolder, into: recordFolder)

        let stagedChunks = try chunkFiles(
            at: stagingFolder.appendingPathComponent("Chunks", isDirectory: true)
        )
        if metadataData == nil, stagedChunks.isEmpty {
            try? FileManager.default.removeItem(at: stagingFolder)
            return .unchanged
        }
        var chunks: [AudioChunkManifest] = []
        for url in stagedChunks {
            let size = try fileSize(at: url)
            chunks.append(AudioChunkManifest(
                filename: url.lastPathComponent,
                index: Self.chunkIndex(url),
                sizeBytes: size,
                sha256: try Self.sha256(fileAt: url)
            ))
        }
        var capturedBytes = chunks.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let expectedBytes = metadata.sizeBytes.map(Int64.init)
        let sequenceIsComplete = chunks.enumerated().allSatisfy { offset, chunk in
            chunk.index == offset
        }
        var isPartial = forcePartial
            || recoveredHistoryOnly
            || (stagedChunks.isEmpty && existing?.isPartial != false)
            || decodedMetadata == nil
            || metadata.status != "completed"
            || !metadata.compatibilityIssues.isEmpty
            || expectedBytes == nil
            || expectedBytes != capturedBytes
            || !sequenceIsComplete

        let audioURL = recordFolder.appendingPathComponent("audio.webm")
        let assembledAudio = stagingFolder.appendingPathComponent(".assembled-audio.webm")
        defer { try? FileManager.default.removeItem(at: assembledAudio) }
        var replacementAudio: URL?
        var audioHash: String?
        var retainAudio = false
        if let existing, existing.audioSizeBytes > 0 {
            let prior = try store.audioManifest(for: existing, verifyAudio: false)
            let preservesCompleteAudio = !existing.isPartial
                && (isPartial || capturedBytes <= existing.audioSizeBytes)
            if preservesCompleteAudio || chunks.isEmpty {
                // Source cleanup, incompatible metadata and metadata-only retries
                // cannot downgrade audio which was already safely captured.
                chunks = prior.chunks
                capturedBytes = existing.audioSizeBytes
                isPartial = existing.isPartial
                retainAudio = true
            } else {
                for old in prior.chunks {
                    guard let candidate = chunks.first(where: { $0.index == old.index }),
                          candidate.sizeBytes >= old.sizeBytes else {
                        throw ArchiveError.invalidRecord("Staged audio is missing previously captured chunks. The archive and staging were preserved.")
                    }
                    if candidate != old {
                        let file = stagingFolder.appendingPathComponent("Chunks").appendingPathComponent(candidate.filename)
                        let input = try FileHandle(forReadingFrom: file)
                        defer { try? input.close() }
                        guard let prefix = try input.read(upToCount: Int(old.sizeBytes)),
                              Int64(prefix.count) == old.sizeBytes, Self.sha256(prefix) == old.sha256 else {
                            throw ArchiveError.invalidRecord("Staged audio conflicts with previously captured audio. Both copies were preserved.")
                        }
                    }
                }
                retainAudio = chunks == prior.chunks
            }
            if retainAudio { audioHash = existing.audioSHA256 }
        }
        if !retainAudio, !stagedChunks.isEmpty {
            if let existing { _ = try store.audioManifest(for: existing) }
            try assembleAudio(from: stagedChunks, at: assembledAudio)
            audioHash = try Self.sha256(fileAt: assembledAudio)
            replacementAudio = assembledAudio
        } else if !retainAudio, FileManager.default.fileExists(atPath: audioURL.path) {
            audioHash = try Self.sha256(fileAt: audioURL)
        }

        let metadataHash = metadataData.map(Self.sha256)
        let firstCapturedAt = existing?.firstCapturedAt ?? now
        let status = metadata.status
            ?? (metadataData == nil ? "source_missing" : "metadata_unreadable")
        let surface = DictationSurface(rawValue: metadata.surface ?? "") ?? .unknown
        let transcript = metadata.text ?? ""
        let duration = max(0, (metadata.durationMs ?? 0) / 1_000)
        let createdAt = metadata.createdAtMs.map {
            Date(timeIntervalSince1970: $0 / 1_000)
        } ?? existing?.createdAt ?? now
        let materiallyChanged = existing == nil
            || existing?.createdAt != createdAt
            || existing?.durationSeconds != duration
            || existing?.status != status
            || existing?.surface != surface
            || existing?.transcript != transcript
            || existing?.mimeType != metadata.mimeType
            || existing?.audioSizeBytes != capturedBytes
            || existing?.expectedSizeBytes != expectedBytes
            || existing?.audioSHA256 != audioHash
            || existing?.metadataSHA256 != metadataHash
            || existing?.isPartial != isPartial
        if !materiallyChanged { return .unchanged }
        if retainAudio, let existing { _ = try store.audioManifest(for: existing) }
        let effectiveUpdatedAt = materiallyChanged ? now : (existing?.updatedAt ?? now)
        let manifest = RecordingManifest(
            recordID: recordID,
            sourceKey: info.sourceKey,
            capturedAt: firstCapturedAt,
            updatedAt: effectiveUpdatedAt,
            sourceStatus: status,
            mimeType: metadata.mimeType,
            expectedSizeBytes: expectedBytes,
            capturedSizeBytes: capturedBytes,
            isPartial: isPartial,
            audioSHA256: audioHash,
            metadataSHA256: metadataHash,
            chunks: chunks
        )
        let record = ArchivedDictationRecord(
            id: recordID,
            sourceKey: info.sourceKey,
            createdAt: createdAt,
            durationSeconds: duration,
            status: status,
            surface: surface,
            transcript: transcript,
            mimeType: metadata.mimeType,
            audioSizeBytes: capturedBytes,
            expectedSizeBytes: expectedBytes,
            archiveFolderURL: recordFolder,
            audioSHA256: audioHash,
            metadataSHA256: metadataHash,
            isPartial: isPartial,
            firstCapturedAt: firstCapturedAt,
            updatedAt: effectiveUpdatedAt
        )
        try publication.prepare(record: record, manifest: manifest, metadata: metadataData,
                                audio: replacementAudio, in: stagingFolder)
        try publication.resume(in: stagingFolder)
        secureFiles(in: recordFolder)

        if !isPartial, metadata.status != "recording" {
            try? FileManager.default.removeItem(at: stagingFolder)
        }
        return existing == nil ? .imported : (materiallyChanged ? .updated : .unchanged)
    }

    private func updateMetadataOnly(
        existing: ArchivedDictationRecord,
        metadata: SourceMetadata,
        metadataData: Data,
        now: Date
    ) throws -> CaptureDisposition {
        // Missing/corrupt manifests are errors even when metadata is unchanged.
        // Never bless an index-only update with no verifiable audio provenance.
        let prior = try store.audioManifest(for: existing, verifyAudio: false)
        let metadataHash = Self.sha256(metadataData)
        let status = metadata.status ?? "unknown"
        let surface = DictationSurface(rawValue: metadata.surface ?? "") ?? .unknown
        let transcript = metadata.text ?? ""
        let duration = max(0, (metadata.durationMs ?? 0) / 1_000)
        let expected = metadata.sizeBytes.map(Int64.init)
        let changed = existing.metadataSHA256 != metadataHash
            || existing.status != status
            || existing.surface != surface
            || existing.transcript != transcript
            || existing.durationSeconds != duration
            || existing.expectedSizeBytes != expected
        guard changed else { return .unchanged }
        _ = try store.audioManifest(for: existing)

        let manifest = RecordingManifest(
                recordID: existing.id,
                sourceKey: existing.sourceKey,
                capturedAt: prior.capturedAt,
                updatedAt: now,
                sourceStatus: status,
                mimeType: metadata.mimeType,
                expectedSizeBytes: expected,
                capturedSizeBytes: existing.audioSizeBytes,
                isPartial: existing.isPartial,
                audioSHA256: existing.audioSHA256,
                metadataSHA256: metadataHash,
                chunks: prior.chunks
            )

        let record = ArchivedDictationRecord(
            id: existing.id,
            sourceKey: existing.sourceKey,
            createdAt: metadata.createdAtMs.map {
                Date(timeIntervalSince1970: $0 / 1_000)
            } ?? existing.createdAt,
            durationSeconds: duration,
            status: status,
            surface: surface,
            transcript: transcript,
            mimeType: metadata.mimeType,
            audioSizeBytes: existing.audioSizeBytes,
            expectedSizeBytes: expected,
            archiveFolderURL: existing.archiveFolderURL,
            audioSHA256: existing.audioSHA256,
            metadataSHA256: metadataHash,
            isPartial: existing.isPartial,
            isDeleted: existing.isDeleted,
            deletedAt: existing.deletedAt,
            firstCapturedAt: existing.firstCapturedAt,
            updatedAt: now
        )
        let stagingFolder = layout.stagingURL.appendingPathComponent(Self.sha256(Data(existing.sourceKey.utf8)))
        try publication.prepare(record: record, manifest: manifest, metadata: metadataData,
                                audio: nil, in: stagingFolder)
        try publication.resume(in: stagingFolder)
        secureFiles(in: existing.archiveFolderURL)
        return .updated
    }

    private func canUpdateMetadataOnly(
        existing: ArchivedDictationRecord,
        metadata: SourceMetadata
    ) -> Bool {
        guard
            !existing.isPartial,
            existing.hasPlayableAudio,
            metadata.status == "completed",
            metadata.compatibilityIssues.isEmpty,
            let expected = metadata.sizeBytes.map(Int64.init)
        else { return false }
        return existing.audioSizeBytes == expected
    }

    private static func hasTranscript(_ data: Data) -> Bool {
        guard let metadata = try? JSONDecoder().decode(SourceMetadata.self, from: data) else { return false }
        return !(metadata.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func preserveMetadata(_ data: Data, in folder: URL) throws {
        let history = folder.appendingPathComponent("Metadata History", isDirectory: true)
        try FileManager.default.createDirectory(
            at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let destination = history.appendingPathComponent(Self.sha256(data) + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw ArchiveError.invalidRecord("A preserved metadata snapshot failed its checksum check.")
            }
            return
        }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func mergeMetadataHistory(from stagingFolder: URL, into recordFolder: URL) throws {
        let history = stagingFolder.appendingPathComponent("Metadata History", isDirectory: true)
        guard FileManager.default.fileExists(atPath: history.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            guard file.lastPathComponent == Self.sha256(data) + ".json" else {
                throw ArchiveError.invalidRecord("A staged metadata snapshot failed its checksum check.")
            }
            try preserveMetadata(data, in: recordFolder)
        }
    }

    private func copyStableFileIfNeeded(from source: URL, to destination: URL) throws -> Bool {
        let sizeBefore = try fileSize(at: source)
        if FileManager.default.fileExists(atPath: destination.path),
           try fileSize(at: destination) == sizeBefore,
           try Self.sha256(fileAt: source) == Self.sha256(fileAt: destination) {
            return true
        }
        let data = try Data(contentsOf: source)
        let sizeAfter = try fileSize(at: source)
        let hashAfterRead = try Self.sha256(fileAt: source)
        guard
            sizeBefore == sizeAfter,
            Int64(data.count) == sizeAfter,
            Self.sha256(data) == hashAfterRead
        else {
            return false
        }
        try data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return true
    }

    private func assembleAudio(from chunks: [URL], at destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".audio-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ArchiveError.invalidRecord("The combined audio file could not be created.")
        }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            do {
                for chunk in chunks {
                    let input = try FileHandle(forReadingFrom: chunk)
                    defer { try? input.close() }
                    while try autoreleasepool(invoking: {
                        guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                        try output.write(contentsOf: data)
                        return true
                    }) {}
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func saveHealth(
        result: CaptureScanResult,
        settings: CaptureSettings,
        sourceAvailable: Bool,
        now: Date
    ) throws {
        let previous = statusStore.load()
        let changed = result.importedCount + result.updatedCount > 0
        let snapshot = CaptureHealthSnapshot(
            process: processKind,
            processID: getpid(),
            captureEnabled: settings.captureEnabled,
            isPaused: settings.isPaused,
            sourceAvailable: sourceAvailable,
            sourceRecordCount: result.sourceRecordCount,
            archiveRecordCount: (try? store.recordCount()) ?? previous?.archiveRecordCount ?? 0,
            lastScanAt: now,
            lastCaptureAt: changed ? now : previous?.lastCaptureAt,
            lastError: result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
        )
        try statusStore.save(snapshot)
    }

    private func recordingFolders(at root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func chunkFiles(at root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.pathExtension == "chunk"
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            let left = Self.chunkIndex($0)
            let right = Self.chunkIndex($1)
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func writeStagingInfo(_ info: StagingInfo, to folder: URL) throws {
        try JSONEncoder.archiveEncoder.encode(info).write(
            to: folder.appendingPathComponent("source.json"),
            options: .atomic
        )
    }

    private func loadStagingInfo(from folder: URL) throws -> StagingInfo {
        let data = try Data(contentsOf: folder.appendingPathComponent("source.json"))
        return try JSONDecoder.archiveDecoder.decode(StagingInfo.self, from: data)
    }

    private func secureFiles(in folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        for filename in ["audio.webm", "metadata.json", "manifest.json"] {
            let path = folder.appendingPathComponent(filename).path
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    private static func chunkIndex(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent) ?? .max
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // FileHandle returns autoreleased buffers. Release each one here,
        // including on Swift concurrency threads without a frequent pool drain.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum CaptureDisposition {
    case imported
    case updated
    case unchanged
    case stagedOnly
    case skippedTombstone
}

private struct StagingInfo: Codable {
    let sourceKey: String
}

struct SourceMetadata: Decodable {
    let createdAtMs: Double?
    let durationMs: Double?
    let id: String?
    let mimeType: String?
    let sizeBytes: Int?
    let status: String?
    let surface: String?
    let text: String?
    var decodingIssues: [String] = []

    var compatibilityIssues: [String] {
        var issues = decodingIssues
        if let durationMs, ArchiveDuration.wholeSeconds(durationMs / 1_000) == nil {
            issues.append("duration is outside the supported range")
        }
        if id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { issues.append("record ID is missing") }
        if text == nil { issues.append("transcript field is missing or unreadable") }
        if let status {
            if !["recording", "completed", "cancelled", "interrupted"].contains(status) {
                issues.append("recording status is not recognized")
            }
        } else { issues.append("recording status is missing or unreadable") }
        if let mimeType, !mimeType.lowercased().hasPrefix("audio/webm") {
            issues.append("audio format is not supported for native playback")
        }
        return issues
    }
}

extension SourceMetadata {
    private enum CodingKeys: String, CodingKey {
        case createdAtMs, durationMs, id, mimeType, sizeBytes, status, surface, text
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        var issues: [String] = []
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            do { return try fields.decodeIfPresent(type, forKey: key) }
            catch {
                issues.append("\(key.rawValue) has an unsupported value")
                return nil
            }
        }
        // Decode fields independently. A changed duration field must not
        // withhold an otherwise intact transcript; preserve the raw JSON too.
        createdAtMs = read(Double.self, .createdAtMs)
        durationMs = read(Double.self, .durationMs)
        id = read(String.self, .id)
        mimeType = read(String.self, .mimeType)
        sizeBytes = read(Int.self, .sizeBytes)
        status = read(String.self, .status)
        surface = read(String.self, .surface)
        text = read(String.self, .text)
        decodingIssues = issues
    }
}
