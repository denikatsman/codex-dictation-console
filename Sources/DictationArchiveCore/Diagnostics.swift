import Foundation

public enum PipelineAuditStatus: String, Codable, Sendable {
    case verifiedForExactBuild = "verified_for_exact_build"
    case notAudited = "not_audited"
    case appUnavailable = "app_unavailable"
}

public struct ChatGPTBuildEvidence: Equatable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let appASARSHA256: String?
    public let auditStatus: PipelineAuditStatus
    public let auditDate: Date?
    public let auditSummary: String

    public init(
        appVersion: String,
        buildNumber: String,
        appASARSHA256: String?,
        auditStatus: PipelineAuditStatus,
        auditDate: Date?,
        auditSummary: String
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.appASARSHA256 = appASARSHA256
        self.auditStatus = auditStatus
        self.auditDate = auditDate
        self.auditSummary = auditSummary
    }
}

public struct InstalledChatGPTInspector: Sendable {
    public let appURL: URL?

    public init(appURL: URL? = CodexApplicationLocator.locate()) {
        self.appURL = appURL
    }

    public var buildStamp: CodexBuildStamp { CodexBuildStamp(appURL: appURL) }

    public func inspect() -> ChatGPTBuildEvidence {
        guard let appURL,
              let information = CodexApplicationLocator.information(at: appURL),
              information["CFBundleIdentifier"] as? String == CodexApplicationLocator.bundleIdentifier else {
            return ChatGPTBuildEvidence(
                appVersion: "Not installed",
                buildNumber: "—",
                appASARSHA256: nil,
                auditStatus: .appUnavailable,
                auditDate: nil,
                auditSummary: "The Codex desktop app could not be located. Existing saved recordings can still be archived; new recordings depend on Codex writing its local history."
            )
        }
        let version = information["CFBundleShortVersionString"] as? String
            ?? "Unknown"
        let build = information["CFBundleVersion"] as? String ?? "Unknown"
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")
        let hash = try? DictationCaptureEngine.sha256(fileAt: asarURL)

        if let hash, let audit = Self.knownAudits[hash] {
            return ChatGPTBuildEvidence(
                appVersion: version,
                buildNumber: build,
                appASARSHA256: hash,
                auditStatus: .verifiedForExactBuild,
                auditDate: audit.date,
                auditSummary: audit.summary
            )
        }
        return ChatGPTBuildEvidence(
            appVersion: version,
            buildNumber: build,
            appASARSHA256: hash,
            auditStatus: .notAudited,
            auditDate: nil,
            auditSummary: "This exact Codex build has not been audited. Capture continues reading its saved files and reports format problems; microphone operation, successful transcription, and insertion into another app are not confirmed by an archive scan."
        )
    }

    private static let knownAudits: [String: KnownAudit] = [:]
}

private struct KnownAudit {
    let date: Date
    let summary: String
}
