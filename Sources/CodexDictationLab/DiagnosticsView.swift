import DictationArchiveCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Dictation diagnostics",
                    detail: "What is being captured, what this Codex build proves, and what remains unknowable"
                )

                captureSection
                Divider()
                buildSection
                Divider()
                archiveSection
                Divider()
                boundariesSection
            }
            .padding(28)
            .frame(maxWidth: 1_020, alignment: .leading)
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Capture pipeline")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(state.isVerifyingArchive ? "Verifying…" : "Scan now") {
                    Task { await state.refreshArchive(scanSource: true, verifyFiles: true) }
                }
                .disabled(state.isLoadingArchive || state.isVerifyingArchive)
            }

            DiagnosticRow(
                title: "Codex source history",
                value: state.captureHealth?.sourceAvailable == true ? "Available" : "Unavailable",
                detail: "Read only: ~/.codex/dictation-history",
                symbol: state.captureHealth?.sourceAvailable == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                color: state.captureHealth?.sourceAvailable == true ? .green : .orange
            )
            DiagnosticRow(
                title: "Always-on helper",
                value: state.captureNeedsAttention ? "Needs attention" : state.helperIsRunning ? "Running" : state.loginItemState.title,
                detail: state.helperIsRunning
                    ? "The background capture worker watches new folders and audio chunks, with a full reconciliation every 15 seconds."
                    : state.loginItemState.detail,
                symbol: state.helperIsRunning ? "waveform.badge.mic" : "moon.zzz",
                color: state.helperIsRunning && !state.captureNeedsAttention ? .green : .orange
            )
            DiagnosticRow(
                title: "Last source scan",
                value: state.captureHealth.map { LabFormatting.dateTime($0.lastScanAt) } ?? "Not yet",
                detail: state.captureHealth.map {
                    "\($0.sourceRecordCount) source folders seen; \($0.archiveRecordCount) permanent records present."
                } ?? "The first scan has not written a health snapshot yet.",
                symbol: state.captureHealth?.lastError == nil ? "checkmark.arrow.trianglehead.counterclockwise" : "exclamationmark.triangle.fill",
                color: state.captureHealth?.lastError == nil ? .blue : .red
            )
            if state.captureNeedsAttention, state.captureHealth?.lastError == nil {
                Text(state.helperLaunchError ?? "A recent successful capture scan has not been reported. The app is attempting to recover background capture.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = state.captureHealth?.lastError {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Installed Codex build")
                .font(.title3.weight(.semibold))
            if let evidence = state.buildEvidence {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: auditSymbol(evidence.auditStatus))
                        .font(.title2)
                        .foregroundStyle(auditColor(evidence.auditStatus))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(auditTitle(evidence.auditStatus))
                            .font(.headline)
                        Text(evidence.auditSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(15)
                .background(auditColor(evidence.auditStatus).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

                if let path = state.installedCodexPath {
                    LabeledContent("Application", value: path)
                }
                LabeledContent("Version", value: evidence.appVersion)
                LabeledContent("Build", value: evidence.buildNumber)
                if let hash = evidence.appASARSHA256 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("app.asar SHA-256")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(hash)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let auditDate = evidence.auditDate {
                    LabeledContent(
                        "Exact-build audit",
                        value: auditDate.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            } else {
                ProgressView("Hashing the installed build")
            }
        }
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Archive integrity")
                .font(.title3.weight(.semibold))
            DiagnosticRow(
                title: "SQLite integrity check",
                value: state.archiveIntegrity == "ok" ? "OK" : state.archiveIntegrity,
                detail: "The durable index uses SQLite WAL mode and a full-text transcript index.",
                symbol: state.archiveIntegrity == "ok" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                color: state.archiveIntegrity == "ok" ? .green : .red
            )
            DiagnosticRow(
                title: "Audio verification",
                value: verificationValue,
                detail: verificationDetail,
                symbol: state.archiveVerification?.isHealthy == true && state.archiveVerificationError == nil
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill",
                color: state.archiveVerification?.isHealthy == true && state.archiveVerificationError == nil ? .green : .orange
            )
            if let issues = state.archiveVerification?.issues, !issues.isEmpty {
                ForEach(issues.prefix(8)) { issue in
                    Text("\(issue.recordID.prefix(8)): \(issue.message)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if issues.count > 8 {
                    Text("Showing 8 of \(issues.count) issues.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Show permanent archive") { state.revealArchive() }
                Button("Show Codex source") { state.revealSourceHistory() }
            }
        }
    }

    private var verificationValue: String {
        if state.isVerifyingArchive { return "Checking…" }
        if state.archiveVerificationError != nil { return "Check failed" }
        guard let verification = state.archiveVerification else { return "Not checked" }
        if verification.isHealthy { return "\(verification.verifiedRecordCount) verified" }
        return "\(verification.issues.count) issue\(verification.issues.count == 1 ? "" : "s")"
    }

    private var verificationDetail: String {
        if let error = state.archiveVerificationError {
            return "The latest verification could not finish. \(error) Run Scan now to retry."
        }
        guard let verification = state.archiveVerification else {
            return "Run a scan to verify archived audio, metadata, manifests, and checksums."
        }
        let partial = state.statistics.partialCount == 0
            ? "No partial source captures."
            : "\(state.statistics.partialCount) source capture\(state.statistics.partialCount == 1 ? " is" : "s are") partial."
        return "SHA-256, byte size, metadata, and manifest checked \(LabFormatting.relative(verification.checkedAt)). \(partial)"
    }

    private var boundariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Honest boundaries")
                .font(.title3.weight(.semibold))
            BoundaryRow(
                title: "Known exactly",
                detail: "The transcript text Codex wrote, source-reported duration/status/surface, captured audio bytes, file sizes, and checksums.",
                symbol: "equal.circle.fill",
                color: .green
            )
            BoundaryRow(
                title: "Known only for audited builds",
                detail: "Whether the installed app’s normal dictation path invokes a model-based cleanup stage. Claims are shown only when the full app.asar hash matches a reviewed build.",
                symbol: "checkmark.shield",
                color: .blue
            )
            BoundaryRow(
                title: "Not exposed",
                detail: "A per-dictation token debit, exact server transcription model, or exact dollar cost. The utility deliberately shows no invented token or cost estimate.",
                symbol: "questionmark.circle.fill",
                color: .orange
            )
            Text("The account meter on Overview is deliberately separate. It describes the signed-in Codex account as a whole and cannot attribute usage to one recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func auditTitle(_ status: PipelineAuditStatus) -> String {
        switch status {
        case .verifiedForExactBuild: "Exact build has reviewed dictation evidence"
        case .notAudited: "No pipeline claim for this build"
        case .appUnavailable: "Codex is unavailable"
        }
    }

    private func auditSymbol(_ status: PipelineAuditStatus) -> String {
        switch status {
        case .verifiedForExactBuild: "checkmark.shield.fill"
        case .notAudited: "questionmark.diamond.fill"
        case .appUnavailable: "app.dashed"
        }
    }

    private func auditColor(_ status: PipelineAuditStatus) -> Color {
        switch status {
        case .verifiedForExactBuild: .green
        case .notAudited: .orange
        case .appUnavailable: .secondary
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(value)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct BoundaryRow: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
