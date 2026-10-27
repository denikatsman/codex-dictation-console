import Foundation

public enum DictationSurface: String, Codable, CaseIterable, Identifiable, Sendable {
    case composer
    case global
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .composer: "Composer"
        case .global: "Global"
        case .unknown: "Unknown"
        }
    }

    public var symbol: String {
        switch self {
        case .composer: "message"
        case .global: "globe"
        case .unknown: "questionmark.circle"
        }
    }
}

public struct ArchivedDictationRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sourceKey: String
    public let createdAt: Date
    public let durationSeconds: Double
    public let status: String
    public let surface: DictationSurface
    public let transcript: String
    public let mimeType: String?
    public let audioSizeBytes: Int64
    public let expectedSizeBytes: Int64?
    public let archiveFolderURL: URL
    public let audioSHA256: String?
    public let metadataSHA256: String?
    public let isPartial: Bool
    public let isDeleted: Bool
    public let deletedAt: Date?
    public let firstCapturedAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        sourceKey: String,
        createdAt: Date,
        durationSeconds: Double,
        status: String,
        surface: DictationSurface,
        transcript: String,
        mimeType: String?,
        audioSizeBytes: Int64,
        expectedSizeBytes: Int64?,
        archiveFolderURL: URL,
        audioSHA256: String?,
        metadataSHA256: String?,
        isPartial: Bool,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        firstCapturedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.status = status
        self.surface = surface
        self.transcript = transcript
        self.mimeType = mimeType
        self.audioSizeBytes = audioSizeBytes
        self.expectedSizeBytes = expectedSizeBytes
        self.archiveFolderURL = archiveFolderURL
        self.audioSHA256 = audioSHA256
        self.metadataSHA256 = metadataSHA256
        self.isPartial = isPartial
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.firstCapturedAt = firstCapturedAt
        self.updatedAt = updatedAt
    }

    public var audioURL: URL {
        archiveFolderURL.appendingPathComponent("audio.webm")
    }

    public var metadataURL: URL {
        archiveFolderURL.appendingPathComponent("metadata.json")
    }

    public var manifestURL: URL {
        archiveFolderURL.appendingPathComponent("manifest.json")
    }

    public var wordCount: Int {
        transcript.split(whereSeparator: { $0.isWhitespace }).count
    }

    public var characterCount: Int { transcript.count }

    public var wordsPerMinute: Int? {
        guard durationSeconds >= 1, ArchiveDuration.wholeSeconds(durationSeconds) != nil, wordCount > 0 else { return nil }
        let rate = (Double(wordCount) / durationSeconds * 60).rounded()
        guard rate < Double(Int.max) else { return nil }
        return Int(rate)
    }

    public var hasPlayableAudio: Bool {
        audioSizeBytes > 0 && FileManager.default.fileExists(atPath: audioURL.path)
    }

    public var partialCaptureTitle: String {
        status == "cancelled" ? "Source recording cancelled" : "Partial source capture"
    }

    public var partialCaptureExplanation: String {
        if status == "cancelled", expectedSizeBytes == audioSizeBytes, audioSHA256 != nil {
            return "Codex cancelled this recording. All reported audio bytes were archived; a Codex transcript may be missing."
        }
        return "Plays the saved audio. Some source audio or metadata is incomplete or could not be verified."
    }
}

public struct ArchiveStatistics: Equatable, Sendable {
    public let recordingCount: Int
    public let durationSeconds: Double
    public let wordCount: Int
    public let archiveSizeBytes: Int64
    public let partialCount: Int

    public init(
        recordingCount: Int,
        durationSeconds: Double,
        wordCount: Int,
        archiveSizeBytes: Int64,
        partialCount: Int
    ) {
        self.recordingCount = recordingCount
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.archiveSizeBytes = archiveSizeBytes
        self.partialCount = partialCount
    }

    public static let empty = ArchiveStatistics(
        recordingCount: 0,
        durationSeconds: 0,
        wordCount: 0,
        archiveSizeBytes: 0,
        partialCount: 0
    )
}

public struct ArchiveVerificationIssue: Codable, Equatable, Sendable, Identifiable {
    public let recordID: String
    public let message: String

    public init(recordID: String, message: String) {
        self.recordID = recordID
        self.message = message
    }

    public var id: String { "\(recordID):\(message)" }
}

public struct ArchiveVerificationSummary: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let checkedRecordCount: Int
    public let verifiedRecordCount: Int
    public let issues: [ArchiveVerificationIssue]

    public init(
        checkedAt: Date,
        checkedRecordCount: Int,
        verifiedRecordCount: Int,
        issues: [ArchiveVerificationIssue]
    ) {
        self.checkedAt = checkedAt
        self.checkedRecordCount = checkedRecordCount
        self.verifiedRecordCount = verifiedRecordCount
        self.issues = issues
    }

    public var isHealthy: Bool { issues.isEmpty }

    public static let empty = ArchiveVerificationSummary(
        checkedAt: .distantPast,
        checkedRecordCount: 0,
        verifiedRecordCount: 0,
        issues: []
    )
}

public struct AudioChunkManifest: Codable, Equatable, Sendable {
    public let filename: String
    public let index: Int
    public let sizeBytes: Int64
    public let sha256: String
}

public struct RecordingManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordID: String
    public let sourceKey: String
    public let capturedAt: Date
    public let updatedAt: Date
    public let sourceStatus: String
    public let mimeType: String?
    public let expectedSizeBytes: Int64?
    public let capturedSizeBytes: Int64
    public let isPartial: Bool
    public let audioSHA256: String?
    public let metadataSHA256: String?
    public let chunks: [AudioChunkManifest]

    // Manifest bytes come from disk and may be damaged. Never trap or lose
    // integer precision while checking them against the durable index.
    var chunkByteCount: Int64? {
        var total: Int64 = 0
        for chunk in chunks {
            guard chunk.sizeBytes >= 0 else { return nil }
            let sum = total.addingReportingOverflow(chunk.sizeBytes)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    public init(
        schemaVersion: Int = 1,
        recordID: String,
        sourceKey: String,
        capturedAt: Date,
        updatedAt: Date,
        sourceStatus: String,
        mimeType: String?,
        expectedSizeBytes: Int64?,
        capturedSizeBytes: Int64,
        isPartial: Bool,
        audioSHA256: String?,
        metadataSHA256: String?,
        chunks: [AudioChunkManifest]
    ) {
        self.schemaVersion = schemaVersion
        self.recordID = recordID
        self.sourceKey = sourceKey
        self.capturedAt = capturedAt
        self.updatedAt = updatedAt
        self.sourceStatus = sourceStatus
        self.mimeType = mimeType
        self.expectedSizeBytes = expectedSizeBytes
        self.capturedSizeBytes = capturedSizeBytes
        self.isPartial = isPartial
        self.audioSHA256 = audioSHA256
        self.metadataSHA256 = metadataSHA256
        self.chunks = chunks
    }
}

public struct CaptureSettings: Codable, Equatable, Sendable {
    public var captureEnabled: Bool
    public var isPaused: Bool
    /// Legacy on-disk preference, preserved for compatibility. ServiceManagement
    /// is authoritative; launches and updates never replay this value.
    public var launchAtLoginRequested: Bool

    public init(
        captureEnabled: Bool = true,
        isPaused: Bool = false,
        launchAtLoginRequested: Bool = true
    ) {
        self.captureEnabled = captureEnabled
        self.isPaused = isPaused
        self.launchAtLoginRequested = launchAtLoginRequested
    }

    public static let `default` = CaptureSettings()
    public static let unavailable = CaptureSettings(captureEnabled: false, isPaused: true, launchAtLoginRequested: false)
}

public enum ArchiveDuration {
    public static func wholeSeconds(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds.rounded() < Double(Int.max) else { return nil }
        return Int(seconds)
    }

    // NaN represents an incomplete total in presentation; raw record metadata
    // stays untouched. Callers must not feed unknown totals into a chart axis.
    public static func total(_ values: [Double]) -> Double {
        var sum = 0.0
        for value in values {
            guard wholeSeconds(value) != nil else { return .nan }
            sum += value
            guard wholeSeconds(sum) != nil else { return .nan }
        }
        return sum
    }
}

public enum CaptureProcessKind: String, Codable, Sendable {
    case helper
    case mainApp = "main_app"
    case manual
}

public struct CaptureHealthSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let process: CaptureProcessKind
    public let processID: Int32
    public let captureEnabled: Bool
    public let isPaused: Bool
    public let sourceAvailable: Bool
    public let sourceRecordCount: Int
    public let archiveRecordCount: Int
    public let lastScanAt: Date
    public let lastCaptureAt: Date?
    public let lastError: String?

    public func isRecentAndHealthy(now: Date = Date(), maximumAge: TimeInterval = 45) -> Bool {
        let age = now.timeIntervalSince(lastScanAt)
        return lastError == nil && age >= -maximumAge && age <= maximumAge
    }

    public init(
        schemaVersion: Int = 1,
        process: CaptureProcessKind,
        processID: Int32,
        captureEnabled: Bool,
        isPaused: Bool,
        sourceAvailable: Bool,
        sourceRecordCount: Int,
        archiveRecordCount: Int,
        lastScanAt: Date,
        lastCaptureAt: Date?,
        lastError: String?
    ) {
        self.schemaVersion = schemaVersion
        self.process = process
        self.processID = processID
        self.captureEnabled = captureEnabled
        self.isPaused = isPaused
        self.sourceAvailable = sourceAvailable
        self.sourceRecordCount = sourceRecordCount
        self.archiveRecordCount = archiveRecordCount
        self.lastScanAt = lastScanAt
        self.lastCaptureAt = lastCaptureAt
        self.lastError = lastError
    }
}

public struct CaptureScanResult: Codable, Equatable, Sendable {
    public let sourceRecordCount: Int
    public let importedCount: Int
    public let updatedCount: Int
    public let skippedTombstoneCount: Int
    public let errors: [String]
    public let completedAt: Date

    public init(
        sourceRecordCount: Int,
        importedCount: Int,
        updatedCount: Int,
        skippedTombstoneCount: Int,
        errors: [String],
        completedAt: Date
    ) {
        self.sourceRecordCount = sourceRecordCount
        self.importedCount = importedCount
        self.updatedCount = updatedCount
        self.skippedTombstoneCount = skippedTombstoneCount
        self.errors = errors
        self.completedAt = completedAt
    }
}

public struct ArchiveLayout: Sendable {
    public let applicationSupportURL: URL
    public let archiveURL: URL
    public let databaseURL: URL
    public let recordingsURL: URL
    public let stagingURL: URL
    public let deletionStagingURL: URL
    public let captureLockURL: URL
    public let settingsURL: URL
    public let statusURL: URL

    public init(applicationSupportURL: URL? = nil) {
        let base = applicationSupportURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Codex Dictation Lab", isDirectory: true)
        self.applicationSupportURL = base
        archiveURL = base.appendingPathComponent("Archive", isDirectory: true)
        databaseURL = archiveURL.appendingPathComponent("archive.sqlite3")
        recordingsURL = archiveURL.appendingPathComponent("Recordings", isDirectory: true)
        stagingURL = archiveURL.appendingPathComponent("Staging", isDirectory: true)
        deletionStagingURL = archiveURL.appendingPathComponent("Deletion Staging", isDirectory: true)
        captureLockURL = archiveURL.appendingPathComponent("capture.lock")
        settingsURL = base.appendingPathComponent("capture-settings.json")
        statusURL = base.appendingPathComponent("capture-status.json")
    }

    public func prepare() throws {
        let fileManager = FileManager.default
        for directory in [applicationSupportURL, archiveURL, recordingsURL, stagingURL, deletionStagingURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

public enum ArchiveError: LocalizedError {
    case sqlite(String)
    case invalidRecord(String)
    case unsafeArchivePath
    case missingRecord
    case noAudioChunks
    case captureLock(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Archive database error: \(message)"
        case .invalidRecord(let message): "The source recording is invalid: \(message)"
        case .unsafeArchivePath: "The archive refused an unsafe file path."
        case .missingRecord: "The archived recording no longer exists."
        case .noAudioChunks: "No audio chunks were available for this recording."
        case .captureLock(let message): "The capture lock could not be used: \(message)"
        }
    }
}

extension JSONEncoder {
    public static var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
