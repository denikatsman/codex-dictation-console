import DictationArchiveCore
import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case history
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .history: "History"
        case .diagnostics: "Dictation Diagnostics"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .history: "text.bubble"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

struct MeterWindowSnapshot: Codable, Equatable, Sendable {
    let usedPercent: Int?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
}

struct MeterBucketSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let primary: MeterWindowSnapshot?
    let secondary: MeterWindowSnapshot?
}

struct AccountUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let planType: String?
    let buckets: [MeterBucketSnapshot]
    let lifetimeTokens: Int64?
    let latestDailyTokens: Int64?

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        planType: String?,
        buckets: [MeterBucketSnapshot],
        lifetimeTokens: Int64?,
        latestDailyTokens: Int64?
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.planType = planType
        self.buckets = buckets
        self.lifetimeTokens = lifetimeTokens
        self.latestDailyTokens = latestDailyTokens
    }

    var codexBucket: MeterBucketSnapshot? {
        buckets.first(where: { $0.id == "codex" })
    }
}

enum LoginItemState: Equatable {
    case enabled
    case requiresApproval
    case disabled
    case unavailable
    case failed(String)

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required"
        case .disabled: "Off"
        case .unavailable: "Unavailable in this build"
        case .failed: "Could not update"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            "Codex Dictation Console is enabled in macOS Open at Login."
        case .requiresApproval:
            "macOS requires approval in System Settings › General › Login Items."
        case .disabled:
            "The app will not automatically open at the next login. macOS controls this setting."
        case .unavailable:
            "Open at Login is available from the installed app."
        case .failed(let message):
            message
        }
    }
}

struct DailyArchiveActivity: Identifiable, Equatable {
    let day: Date
    let durationSeconds: Double
    let recordingCount: Int

    var id: Date { day }
}
