import Foundation
import SQLite3
import Darwin

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ArchiveStore: Sendable {
    public static let didChangeNotification = Notification.Name("local.codex-dictation-console.archive-changed")
    public let layout: ArchiveLayout

    public init(layout: ArchiveLayout = ArchiveLayout()) {
        self.layout = layout
    }

    public func waitForPendingWrites() throws {
        try ArchiveLock.withExclusiveAccess(to: layout) {}
    }

    public func prepare() throws {
        try layout.prepare()
        let exists = FileManager.default.fileExists(atPath: layout.databaseURL.path)
        if !exists {
            // An index is not disposable: it also owns deletion and source identity.
            // Never silently replace a lost index with an empty, healthy library.
            for folder in [layout.recordingsURL, layout.stagingURL, layout.deletionStagingURL] {
                if try !FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty {
                    throw ArchiveError.invalidRecord("The archive index is missing. Saved files were preserved; restore the index before capturing or exporting.")
                }
            }
        } else {
            let reader = try ArchiveDatabase(url: layout.databaseURL, readOnly: true)
            let version = try reader.prepare("PRAGMA user_version;")
            if try version.step() == SQLITE_ROW, version.int64(at: 0) == 2 { return }
        }
        let database = try ArchiveDatabase(url: layout.databaseURL, create: !exists)
        try migrate(database)
    }

    public func upsert(_ record: ArchivedDictationRecord) throws {
        try prepare()
        let database = try ArchiveDatabase(url: layout.databaseURL)
        try database.execute("BEGIN IMMEDIATE;")
        do {
            let owner = try database.prepare("SELECT source_key FROM records WHERE id = ?;")
            try owner.bind(record.id, at: 1)
            if try owner.step() == SQLITE_ROW, owner.string(at: 0) != record.sourceKey {
                throw ArchiveError.invalidRecord("This record ID already belongs to another source.")
            }
            let statement = try database.prepare(
                """
                INSERT INTO records (
                    id, source_key, created_at, duration_seconds, status, surface,
                    transcript, mime_type, audio_size_bytes, expected_size_bytes,
                    archive_folder, audio_sha256, metadata_sha256, is_partial,
                    is_deleted, deleted_at, first_captured_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_key = excluded.source_key,
                    created_at = excluded.created_at,
                    duration_seconds = excluded.duration_seconds,
                    status = excluded.status,
                    surface = excluded.surface,
                    transcript = excluded.transcript,
                    mime_type = excluded.mime_type,
                    audio_size_bytes = excluded.audio_size_bytes,
                    expected_size_bytes = excluded.expected_size_bytes,
                    archive_folder = excluded.archive_folder,
                    audio_sha256 = excluded.audio_sha256,
                    metadata_sha256 = excluded.metadata_sha256,
                    is_partial = excluded.is_partial,
                    first_captured_at = records.first_captured_at,
                    updated_at = excluded.updated_at;
                """
            )
            try statement.bind(record.id, at: 1)
            try statement.bind(record.sourceKey, at: 2)
            try statement.bind(record.createdAt.timeIntervalSince1970, at: 3)
            try statement.bind(record.durationSeconds, at: 4)
            try statement.bind(record.status, at: 5)
            try statement.bind(record.surface.rawValue, at: 6)
            try statement.bind(record.transcript, at: 7)
            try statement.bind(record.mimeType, at: 8)
            try statement.bind(record.audioSizeBytes, at: 9)
            try statement.bind(record.expectedSizeBytes, at: 10)
            try statement.bind(record.archiveFolderURL.path, at: 11)
            try statement.bind(record.audioSHA256, at: 12)
            try statement.bind(record.metadataSHA256, at: 13)
            try statement.bind(record.isPartial, at: 14)
            try statement.bind(record.isDeleted, at: 15)
            try statement.bind(record.deletedAt?.timeIntervalSince1970, at: 16)
            try statement.bind(record.firstCapturedAt.timeIntervalSince1970, at: 17)
            try statement.bind(record.updatedAt.timeIntervalSince1970, at: 18)
            try statement.finish()

            let removeSearch = try database.prepare("DELETE FROM record_search WHERE record_id = ?;")
            try removeSearch.bind(record.id, at: 1)
            try removeSearch.finish()

            let insertSearch = try database.prepare(
                "INSERT INTO record_search(record_id, transcript) VALUES (?, ?);"
            )
            try insertSearch.bind(record.id, at: 1)
            try insertSearch.bind(record.transcript, at: 2)
            try insertSearch.finish()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    public func record(id: String) throws -> ArchivedDictationRecord? {
        try fetch(whereClause: "id = ?", bindings: [.text(id)]).first
    }

    public func record(sourceKey: String) throws -> ArchivedDictationRecord? {
        try fetch(whereClause: "source_key = ?", bindings: [.text(sourceKey)]).first
    }

    func resolvedRecordID(sourceKey: String, metadataID: String?) throws -> String {
        if let existing = try record(sourceKey: sourceKey) { return existing.id }
        let preferred = metadataID.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? sourceKey
        if try record(id: preferred) == nil { return preferred }
        let base = "source:" + DictationCaptureEngine.sha256(Data(sourceKey.utf8))
        var candidate = base
        var suffix = 0
        while try record(id: candidate) != nil {
            suffix += 1
            candidate = base + ":\(suffix)"
        }
        return candidate
    }

    func audioManifest(for record: ArchivedDictationRecord, verifyAudio: Bool = true) throws -> RecordingManifest {
        let manifest = try JSONDecoder.archiveDecoder.decode(RecordingManifest.self, from: Data(contentsOf: record.manifestURL))
        guard manifest.schemaVersion == 1, manifest.recordID == record.id,
              manifest.sourceKey == record.sourceKey,
              manifest.capturedSizeBytes == record.audioSizeBytes,
              manifest.audioSHA256 == record.audioSHA256,
              manifest.chunkByteCount == record.audioSizeBytes else {
            throw ArchiveError.invalidRecord("The saved audio manifest disagrees with the archive. Existing files were preserved.")
        }
        if record.audioSizeBytes > 0 {
            guard let hash = record.audioSHA256,
                  try (!verifyAudio || DictationCaptureEngine.sha256(fileAt: record.audioURL) == hash),
                  Int64(try record.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == record.audioSizeBytes else {
                throw ArchiveError.invalidRecord("The saved audio failed verification. Existing files were preserved.")
            }
        }
        return manifest
    }

    public func records(search: String = "", deleted: Bool = false) throws -> [ArchivedDictationRecord] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var clause = "is_deleted = ?"
        var bindings: [SQLiteValue] = [.integer(deleted ? 1 : 0)]
        if !trimmed.isEmpty {
            clause += " AND id IN (SELECT record_id FROM record_search WHERE record_search MATCH ?)"
            bindings.append(.text(Self.ftsQuery(for: trimmed)))
        }
        return try fetch(whereClause: clause, bindings: bindings)
    }

    /// A bounded UI read, independent of full-library loading or verification.
    public func latestFinishedRecords(limit: Int = 10) throws -> [ArchivedDictationRecord] {
        guard (1...100).contains(limit) else { throw ArchiveError.invalidRecord("Invalid recent-record limit.") }
        return try fetch(whereClause: "is_deleted = 0 AND status != 'recording'", bindings: [], limit: limit)
    }

    public func recordCount(deleted: Bool = false) throws -> Int {
        try prepare()
        let database = try ArchiveDatabase(url: layout.databaseURL, readOnly: true)
        let statement = try database.prepare("SELECT COUNT(*) FROM records WHERE is_deleted = ?;")
        try statement.bind(deleted, at: 1)
        guard try statement.step() == SQLITE_ROW else { return 0 }
        return Int(statement.int64(at: 0))
    }

    public func isTombstoned(sourceKey: String, recordID: String? = nil) throws -> Bool {
        try prepare()
        let database = try ArchiveDatabase(url: layout.databaseURL, readOnly: true)
        let statement = try database.prepare(
            "SELECT 1 FROM tombstones WHERE source_key = ? OR record_id = ? LIMIT 1;"
        )
        try statement.bind(sourceKey, at: 1)
        try statement.bind(recordID, at: 2)
        return try statement.step() == SQLITE_ROW
    }

    public func softDelete(id: String, at date: Date = Date()) throws {
        try ArchiveLock.withExclusiveAccess(to: layout) {
            guard let record = try record(id: id) else { throw ArchiveError.missingRecord }
            try prepare()
            let database = try ArchiveDatabase(url: layout.databaseURL)
            try database.execute("BEGIN IMMEDIATE;")
            do {
                let update = try database.prepare(
                    "UPDATE records SET is_deleted = 1, deleted_at = ?, updated_at = ? WHERE id = ?;"
                )
                try update.bind(date.timeIntervalSince1970, at: 1)
                try update.bind(date.timeIntervalSince1970, at: 2)
                try update.bind(id, at: 3)
                try update.finish()
                try insertTombstone(record: record, date: date, database: database)
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        }
    }

    public func restore(id: String, at date: Date = Date()) throws {
        try ArchiveLock.withExclusiveAccess(to: layout) {
            guard !FileManager.default.fileExists(atPath: deletionJournalURL(id: id).path) else {
                throw ArchiveError.invalidRecord("Permanent deletion is pending. Retry cleanup before continuing.")
            }
            guard let record = try record(id: id) else { throw ArchiveError.missingRecord }
            try prepare()
            let database = try ArchiveDatabase(url: layout.databaseURL)
            try database.execute("BEGIN IMMEDIATE;")
            do {
                let update = try database.prepare(
                    "UPDATE records SET is_deleted = 0, deleted_at = NULL, updated_at = ? WHERE id = ?;"
                )
                try update.bind(date.timeIntervalSince1970, at: 1)
                try update.bind(id, at: 2)
                try update.finish()
                let remove = try database.prepare("DELETE FROM tombstones WHERE source_key = ?;")
                try remove.bind(record.sourceKey, at: 1)
                try remove.finish()
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        }
    }

    public func permanentlyDelete(id: String, at date: Date = Date()) throws {
        try ArchiveLock.withExclusiveAccess(to: layout) {
            try prepare()
            let journalURL = deletionJournalURL(id: id)
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                guard let record = try record(id: id) else {
                    let database = try ArchiveDatabase(url: layout.databaseURL)
                    let completed = try database.prepare("SELECT 1 FROM tombstones WHERE record_id = ? AND cleanup_complete = 1;")
                    try completed.bind(id, at: 1)
                    guard try completed.step() == SQLITE_ROW else { throw ArchiveError.missingRecord }
                    return
                }
                guard record.archiveFolderURL.deletingLastPathComponent().standardizedFileURL == layout.recordingsURL.standardizedFileURL else {
                    throw ArchiveError.unsafeArchivePath
                }
                let journal = DeletionJournal(id: id, sourceKey: record.sourceKey,
                    recordingFolder: record.archiveFolderURL.lastPathComponent, requestedAt: date)
                try durableWrite(JSONEncoder.archiveEncoder.encode(journal), to: journalURL)
            }
            try finishDeletion(journalURL: journalURL)
        }
    }

    // Called only while holding the existing archive lock (including from scan).
    // Old UUID quarantine folders have no reliable ownership proof. Leave them
    // untouched and report them; a tombstone alone is not proof of file cleanup.
    func resumeDeletionsWithExclusiveAccess() throws -> [String] {
        var errors: [String] = []
        for entry in try FileManager.default.contentsOfDirectory(at: layout.deletionStagingURL, includingPropertiesForKeys: nil) {
            if entry.lastPathComponent.hasSuffix(".delete.json") {
                do { try finishDeletion(journalURL: entry) }
                catch { errors.append("Permanent deletion pending: \(error.localizedDescription)") }
            } else if FileManager.default.fileExists(atPath: entry.path),
                      !(entry.lastPathComponent.hasSuffix(".pending") && FileManager.default.fileExists(atPath: String(entry.path.dropLast(".pending".count)))) {
                errors.append("Unjournaled deletion material was preserved: \(entry.lastPathComponent)")
            }
        }
        return errors
    }

    private func deletionJournalURL(id: String) -> URL {
        layout.deletionStagingURL.appendingPathComponent(DictationCaptureEngine.sha256(Data(id.utf8)) + ".delete.json")
    }

    private func finishDeletion(journalURL: URL) throws {
        let journal = try JSONDecoder.archiveDecoder.decode(DeletionJournal.self, from: Data(contentsOf: journalURL))
        guard journal.version == 1,
              journalURL.standardizedFileURL.path == deletionJournalURL(id: journal.id).standardizedFileURL.path,
              !journal.recordingFolder.isEmpty, ![".", ".."].contains(journal.recordingFolder),
              !journal.recordingFolder.contains("/") else { throw ArchiveError.unsafeArchivePath }
        let manager = FileManager.default
        let intentDatabase = try ArchiveDatabase(url: layout.databaseURL)
        let intent = try intentDatabase.prepare("INSERT INTO tombstones(source_key, record_id, deleted_at) VALUES (?, ?, ?) ON CONFLICT(source_key) DO NOTHING;")
        try intent.bind(journal.sourceKey, at: 1)
        try intent.bind(journal.id, at: 2)
        try intent.bind(journal.requestedAt.timeIntervalSince1970, at: 3)
        try intent.finish()
        let hide = try intentDatabase.prepare("UPDATE records SET is_deleted = 1, deleted_at = ? WHERE id = ?;")
        try hide.bind(journal.requestedAt.timeIntervalSince1970, at: 1)
        try hide.bind(journal.id, at: 2)
        try hide.finish()
        let quarantine = layout.deletionStagingURL.appendingPathComponent(journalURL.lastPathComponent + ".pending")
        try manager.createDirectory(at: quarantine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let originals = [layout.recordingsURL.appendingPathComponent(journal.recordingFolder),
                         layout.stagingURL.appendingPathComponent(DictationCaptureEngine.sha256(Data(journal.sourceKey.utf8)))]
        for (index, original) in originals.enumerated() where manager.fileExists(atPath: original.path) {
            let target = quarantine.appendingPathComponent(String(index))
            guard !manager.fileExists(atPath: target.path) else {
                throw ArchiveError.invalidRecord("Conflicting deletion files were preserved for inspection.")
            }
            try manager.moveItem(at: original, to: target)
        }
        try manager.removeItem(at: quarantine)
        for directory in [layout.recordingsURL, layout.stagingURL, layout.deletionStagingURL] {
            try synchronizeDeletionDirectory(directory)
        }
        // Publish success only after BOTH recording and capture staging are gone.
        let database = try ArchiveDatabase(url: layout.databaseURL)
        try database.execute("BEGIN IMMEDIATE;")
        do {
            let tombstone = try database.prepare("INSERT INTO tombstones(source_key, record_id, deleted_at, cleanup_complete) VALUES (?, ?, ?, 1) ON CONFLICT(source_key) DO UPDATE SET record_id = excluded.record_id, deleted_at = excluded.deleted_at, cleanup_complete = 1;")
            try tombstone.bind(journal.sourceKey, at: 1)
            try tombstone.bind(journal.id, at: 2)
            try tombstone.bind(journal.requestedAt.timeIntervalSince1970, at: 3)
            try tombstone.finish()
            for sql in ["DELETE FROM record_search WHERE record_id = ?;", "DELETE FROM records WHERE id = ?;"] {
                let statement = try database.prepare(sql)
                try statement.bind(journal.id, at: 1)
                try statement.finish()
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        try manager.removeItem(at: journalURL)
        try synchronizeDeletionDirectory(layout.deletionStagingURL)
    }

    public func statistics(
        for suppliedRecords: [ArchivedDictationRecord]? = nil
    ) throws -> ArchiveStatistics {
        let activeRecords: [ArchivedDictationRecord]
        if let suppliedRecords {
            activeRecords = suppliedRecords
        } else {
            activeRecords = try records()
        }
        return ArchiveStatistics(
            recordingCount: activeRecords.count,
            durationSeconds: ArchiveDuration.total(activeRecords.map(\.durationSeconds)),
            wordCount: activeRecords.reduce(0) { $0 + $1.wordCount },
            archiveSizeBytes: try directorySize(at: layout.archiveURL),
            partialCount: activeRecords.filter(\.isPartial).count
        )
    }

    public func quickCheck() throws -> String {
        try prepare()
        let database = try ArchiveDatabase(url: layout.databaseURL, readOnly: true)
        let statement = try database.prepare("PRAGMA quick_check;")
        guard try statement.step() == SQLITE_ROW else {
            throw ArchiveError.sqlite("quick_check returned no result")
        }
        return statement.string(at: 0) ?? "unknown"
    }

    public func verifyArchivedFiles(now: Date = Date()) throws -> ArchiveVerificationSummary {
        let identifiers = try Set((records() + records(deleted: true)).map(\.id)).sorted()
        var issues: [ArchiveVerificationIssue] = []
        var checked = 0
        var verified = 0
        for id in identifiers {
            // Keep each record internally consistent, but let capture and
            // deletion proceed between records instead of locking the archive
            // for an entire multi-gigabyte verification.
            let recordIssues: [String]? = try ArchiveLock.withExclusiveAccess(to: layout) {
                try autoreleasepool {
                    guard let current = try record(id: id) else { return nil }
                    do { return try verifyFiles(for: current) }
                    catch { return ["Archived files could not be read: \(error.localizedDescription)"] }
                }
            }
            guard let recordIssues else { continue } // Deleted during verification.
            checked += 1
            if recordIssues.isEmpty { verified += 1 }
            issues.append(contentsOf: recordIssues.map {
                ArchiveVerificationIssue(recordID: id, message: $0)
            })
        }
        return ArchiveVerificationSummary(
            checkedAt: now, checkedRecordCount: checked,
            verifiedRecordCount: verified, issues: issues
        )
    }

    private func verifyFiles(for record: ArchivedDictationRecord) throws -> [String] {
        var recordIssues: [String] = []
        let audioExists = FileManager.default.fileExists(atPath: record.audioURL.path)
        if record.audioSizeBytes > 0, !audioExists {
            recordIssues.append("audio.webm is missing")
        } else if audioExists {
            let size = Int64((try record.audioURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            if size != record.audioSizeBytes {
                recordIssues.append("audio.webm has \(size) bytes; the index expects \(record.audioSizeBytes)")
            }
            if let expectedHash = record.audioSHA256 {
                let actualHash = try DictationCaptureEngine.sha256(fileAt: record.audioURL)
                if actualHash != expectedHash { recordIssues.append("audio.webm checksum does not match") }
            }
        }

        if let expectedHash = record.metadataSHA256 {
            if !FileManager.default.fileExists(atPath: record.metadataURL.path) {
                recordIssues.append("metadata.json is missing")
            } else {
                let metadataData = try Data(contentsOf: record.metadataURL)
                let actualHash = DictationCaptureEngine.sha256(metadataData)
                if actualHash != expectedHash { recordIssues.append("metadata.json checksum does not match") }
                do {
                    let metadata = try JSONDecoder().decode(SourceMetadata.self, from: metadataData)
                    recordIssues.append(contentsOf: metadata.compatibilityIssues.map { "metadata.json: " + $0 })
                    if let id = metadata.id,
                       id != record.id,
                       record.id != record.sourceKey,
                       !record.id.hasPrefix("source:" + DictationCaptureEngine.sha256(Data(record.sourceKey.utf8))) {
                        recordIssues.append("metadata.json has the wrong record ID")
                    }
                    if (metadata.text ?? "") != record.transcript {
                        recordIssues.append("metadata.json has different transcript text")
                    }
                    if (metadata.status ?? "source_missing") != record.status {
                        recordIssues.append("metadata.json has a different source status")
                    }
                    let surface = DictationSurface(rawValue: metadata.surface ?? "") ?? .unknown
                    if surface != record.surface {
                        recordIssues.append("metadata.json has a different dictation surface")
                    }
                    if metadata.mimeType != record.mimeType {
                        recordIssues.append("metadata.json has a different media type")
                    }
                    if metadata.sizeBytes.map(Int64.init) != record.expectedSizeBytes {
                        recordIssues.append("metadata.json has a different expected byte count")
                    }
                    let duration = max(0, (metadata.durationMs ?? 0) / 1_000)
                    if abs(duration - record.durationSeconds) > 0.000_001 {
                        recordIssues.append("metadata.json has a different duration")
                    }
                    if let createdAt = metadata.createdAtMs.map({
                        Date(timeIntervalSince1970: $0 / 1_000)
                    }), abs(createdAt.timeIntervalSince(record.createdAt)) > 0.000_001 {
                        recordIssues.append("metadata.json has a different creation time")
                    }
                } catch {
                    recordIssues.append("metadata.json could not be decoded")
                }
            }
        }

        if !FileManager.default.fileExists(atPath: record.manifestURL.path) {
            recordIssues.append("manifest.json is missing")
        } else {
            do {
                let data = try Data(contentsOf: record.manifestURL)
                let manifest = try JSONDecoder.archiveDecoder.decode(RecordingManifest.self, from: data)
                if manifest.schemaVersion != 1 { recordIssues.append("manifest.json has an unsupported schema version") }
                if manifest.recordID != record.id { recordIssues.append("manifest.json has the wrong record ID") }
                if manifest.sourceKey != record.sourceKey {
                    recordIssues.append("manifest.json has the wrong source key")
                }
                if manifest.sourceStatus != record.status {
                    recordIssues.append("manifest.json has a different source status")
                }
                if manifest.mimeType != record.mimeType {
                    recordIssues.append("manifest.json has a different media type")
                }
                if manifest.capturedSizeBytes != record.audioSizeBytes {
                    recordIssues.append("manifest.json has a different captured byte count")
                }
                if manifest.expectedSizeBytes != record.expectedSizeBytes {
                    recordIssues.append("manifest.json has a different expected byte count")
                }
                if manifest.isPartial != record.isPartial {
                    recordIssues.append("manifest.json has a different partial-capture state")
                }
                if manifest.audioSHA256 != record.audioSHA256 {
                    recordIssues.append("manifest.json has a different audio checksum")
                }
                if manifest.metadataSHA256 != record.metadataSHA256 {
                    recordIssues.append("manifest.json has a different metadata checksum")
                }
                if manifest.chunkByteCount != manifest.capturedSizeBytes {
                    recordIssues.append("manifest.json chunk sizes do not match the captured byte count")
                }
                if !manifest.chunks.enumerated().allSatisfy({ $0.offset == $0.element.index }) {
                    recordIssues.append("manifest.json chunk indexes are not contiguous")
                }
            } catch {
                recordIssues.append("manifest.json could not be decoded")
            }
        }

        let metadataHistory = record.archiveFolderURL.appendingPathComponent("Metadata History")
        if FileManager.default.fileExists(atPath: metadataHistory.path) {
            do {
                for file in try FileManager.default.contentsOfDirectory(at: metadataHistory, includingPropertiesForKeys: nil) {
                    let hash = try DictationCaptureEngine.sha256(fileAt: file)
                    if file.lastPathComponent != hash + ".json" {
                        recordIssues.append("A Metadata History snapshot checksum does not match")
                    }
                }
            } catch {
                recordIssues.append("Metadata History could not be read")
            }
        }

        do {
            _ = try TranscriptRecoveryStore.read(from: record)
        } catch {
            recordIssues.append("Recovered transcripts could not be verified")
        }
        return recordIssues
    }

    public func tombstoneCount() throws -> Int {
        try prepare()
        let database = try ArchiveDatabase(url: layout.databaseURL, readOnly: true)
        let statement = try database.prepare("SELECT COUNT(*) FROM tombstones;")
        guard try statement.step() == SQLITE_ROW else { return 0 }
        return Int(statement.int64(at: 0))
    }

    private func fetch(
        whereClause: String,
        bindings: [SQLiteValue],
        limit: Int? = nil
    ) throws -> [ArchivedDictationRecord] {
        try prepare()
        let database = try ArchiveDatabase(url: layout.databaseURL, readOnly: true)
        let statement = try database.prepare(
            """
            SELECT id, source_key, created_at, duration_seconds, status, surface,
                   transcript, mime_type, audio_size_bytes, expected_size_bytes,
                   archive_folder, audio_sha256, metadata_sha256, is_partial,
                   is_deleted, deleted_at, first_captured_at, updated_at
            FROM records
            WHERE \(whereClause)
            ORDER BY created_at DESC, id ASC \(limit.map { "LIMIT \($0)" } ?? "");
            """
        )
        for (offset, binding) in bindings.enumerated() {
            try statement.bind(binding, at: Int32(offset + 1))
        }

        var records: [ArchivedDictationRecord] = []
        while try statement.step() == SQLITE_ROW {
            guard
                let id = statement.string(at: 0),
                let sourceKey = statement.string(at: 1),
                let status = statement.string(at: 4),
                let surfaceValue = statement.string(at: 5),
                let transcript = statement.string(at: 6),
                let archiveFolder = statement.string(at: 10)
            else {
                throw ArchiveError.sqlite("A required record column was null.")
            }
            records.append(ArchivedDictationRecord(
                id: id,
                sourceKey: sourceKey,
                createdAt: Date(timeIntervalSince1970: statement.double(at: 2)),
                durationSeconds: statement.double(at: 3),
                status: status,
                surface: DictationSurface(rawValue: surfaceValue) ?? .unknown,
                transcript: transcript,
                mimeType: statement.string(at: 7),
                audioSizeBytes: statement.int64(at: 8),
                expectedSizeBytes: statement.optionalInt64(at: 9),
                archiveFolderURL: URL(fileURLWithPath: archiveFolder, isDirectory: true),
                audioSHA256: statement.string(at: 11),
                metadataSHA256: statement.string(at: 12),
                isPartial: statement.bool(at: 13),
                isDeleted: statement.bool(at: 14),
                deletedAt: statement.optionalDouble(at: 15).map(Date.init(timeIntervalSince1970:)),
                firstCapturedAt: Date(timeIntervalSince1970: statement.double(at: 16)),
                updatedAt: Date(timeIntervalSince1970: statement.double(at: 17))
            ))
        }
        return records
    }

    private func insertTombstone(
        record: ArchivedDictationRecord,
        date: Date,
        database: ArchiveDatabase
    ) throws {
        let tombstone = try database.prepare(
            """
            INSERT INTO tombstones(source_key, record_id, deleted_at)
            VALUES (?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                record_id = excluded.record_id,
                deleted_at = excluded.deleted_at,
                cleanup_complete = 0;
            """
        )
        try tombstone.bind(record.sourceKey, at: 1)
        try tombstone.bind(record.id, at: 2)
        try tombstone.bind(date.timeIntervalSince1970, at: 3)
        try tombstone.finish()
    }

    private func migrate(_ database: ArchiveDatabase) throws {
        let version = try database.prepare("PRAGMA user_version;")
        guard try version.step() == SQLITE_ROW else {
            throw ArchiveError.sqlite("The archive schema version could not be read.")
        }
        let currentVersion = version.int64(at: 0)
        guard (0...2).contains(currentVersion) else {
            throw ArchiveError.sqlite("This archive uses schema version \(currentVersion), which this app cannot open. Use a compatible app version; the saved archive has been preserved.")
        }
        if currentVersion == 2 { return }
        try database.execute("BEGIN IMMEDIATE;")
        defer { try? database.execute("ROLLBACK;") }
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY,
                source_key TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL,
                duration_seconds REAL NOT NULL,
                status TEXT NOT NULL,
                surface TEXT NOT NULL,
                transcript TEXT NOT NULL,
                mime_type TEXT,
                audio_size_bytes INTEGER NOT NULL,
                expected_size_bytes INTEGER,
                archive_folder TEXT NOT NULL,
                audio_sha256 TEXT,
                metadata_sha256 TEXT,
                is_partial INTEGER NOT NULL DEFAULT 0,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL,
                first_captured_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS records_created_at_idx ON records(created_at DESC);
            CREATE INDEX IF NOT EXISTS records_deleted_idx ON records(is_deleted, created_at DESC);
            CREATE TABLE IF NOT EXISTS tombstones (
                source_key TEXT PRIMARY KEY,
                record_id TEXT NOT NULL,
                deleted_at REAL NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS record_search USING fts5(
                record_id UNINDEXED,
                transcript,
                tokenize = 'unicode61'
            );
            """
        )
        let columns = try database.prepare("PRAGMA table_info(tombstones);")
        var hasCleanupColumn = false
        while try columns.step() == SQLITE_ROW {
            if columns.string(at: 1) == "cleanup_complete" { hasCleanupColumn = true }
        }
        if !hasCleanupColumn {
            try database.execute("ALTER TABLE tombstones ADD COLUMN cleanup_complete INTEGER NOT NULL DEFAULT 0;")
        }
        try database.execute("PRAGMA user_version = 2;")
        try database.execute("COMMIT;")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: layout.databaseURL.path
        )
    }

    private func directorySize(at root: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func ftsQuery(for text: String) -> String {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return terms.joined(separator: " AND ")
    }
}

private struct DeletionJournal: Codable {
    var version: Int = 1
    let id: String
    let sourceKey: String
    let recordingFolder: String
    let requestedAt: Date
}

private func durableWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
    try synchronizeDeletionDirectory(url.deletingLastPathComponent())
}

private func synchronizeDeletionDirectory(_ url: URL) throws {
    let directory = Darwin.open(url.path, O_RDONLY)
    guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(directory) }
    guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private enum SQLiteValue {
    case text(String)
    case integer(Int64)
}

private final class ArchiveDatabase {
    fileprivate let handle: OpaquePointer

    init(url: URL, create: Bool = false, readOnly: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = (create ? SQLITE_OPEN_CREATE : 0) | (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database."
            if let pointer { sqlite3_close(pointer) }
            throw ArchiveError.sqlite(message)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
        // Ownership transferred to self; deinit also runs on a throwing init.
        if !readOnly {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = FULL;")
            try execute("PRAGMA foreign_keys = ON;")
        }
        secureDatabaseFiles(at: url)
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw ArchiveError.sqlite(message)
        }
    }

    func prepare(_ sql: String) throws -> ArchiveStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        return ArchiveStatement(database: self, handle: statement)
    }
}

private final class ArchiveStatement {
    private let database: ArchiveDatabase
    private let handle: OpaquePointer

    init(database: ArchiveDatabase, handle: OpaquePointer) {
        self.database = database
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ value: SQLiteValue, at index: Int32) throws {
        switch value {
        case .text(let text): try bind(text, at: index)
        case .integer(let integer): try bind(integer, at: index)
        }
    }

    func bind(_ value: String?, at index: Int32) throws {
        let result: Int32
        if let value {
            let utf8 = value.utf8CString
            result = utf8.withUnsafeBufferPointer { buffer in
                sqlite3_bind_text(
                    handle,
                    index,
                    buffer.baseAddress,
                    Int32(buffer.count - 1),
                    sqliteTransient
                )
            }
        } else {
            result = sqlite3_bind_null(handle, index)
        }
        try check(result)
    }

    func bind(_ value: Double?, at index: Int32) throws {
        let result = value.map { sqlite3_bind_double(handle, index, $0) }
            ?? sqlite3_bind_null(handle, index)
        try check(result)
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        let result = value.map { sqlite3_bind_int64(handle, index, $0) }
            ?? sqlite3_bind_null(handle, index)
        try check(result)
    }

    func bind(_ value: Bool, at index: Int32) throws {
        try check(sqlite3_bind_int(handle, index, value ? 1 : 0))
    }

    func step() throws -> Int32 {
        let result = sqlite3_step(handle)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(database.handle)))
        }
        return result
    }

    func finish() throws {
        guard try step() == SQLITE_DONE else {
            throw ArchiveError.sqlite("A write unexpectedly returned a row.")
        }
    }

    func string(at index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(handle, index) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, index))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func optionalInt64(at index: Int32) -> Int64? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : int64(at: index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func optionalDouble(at index: Int32) -> Double? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : double(at: index)
    }

    func bool(at index: Int32) -> Bool {
        sqlite3_column_int(handle, index) != 0
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(database.handle)))
        }
    }
}

private func secureDatabaseFiles(at databaseURL: URL) {
    let fileManager = FileManager.default
    for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
    {
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & 0o777 != 0o600 {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
