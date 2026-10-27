import DictationArchiveCore
import SwiftUI

struct DictationCardSummary {
    var status: String
    var symbol: String
    var warning: String?
    var recordingCount: Int
    var lastArchived: Date?
    var lastScan: Date?
    var latestRecordID: String?

    @MainActor
    init(state: AppState, now: Date = Date()) {
        recordingCount = state.statistics.recordingCount
        lastArchived = state.captureHealth?.lastCaptureAt ?? state.records.first?.firstCapturedAt
        lastScan = state.captureHealth?.lastScanAt
        latestRecordID = state.records.first?.id
        warning = nil
        if state.archiveLoadError != nil { warning = "The archive could not refresh. Open the library for details." }
        else if state.captureHealth?.sourceAvailable == false { warning = "Codex history is unavailable. Check source access in Diagnostics." }
        else if state.helperLaunchError != nil { warning = "The capture helper could not start. Open Diagnostics for details." }
        else if state.captureHealth?.lastError != nil { warning = "The last capture scan reported an error. Open Diagnostics for details." }
        else if let health = state.captureHealth, !health.isRecentAndHealthy(now: now) { warning = "Capture status is stale. The last scan does not confirm current protection." }
        else if state.hasLoadedArchive && state.captureSettings.captureEnabled && !state.captureSettings.isPaused && state.captureHealth == nil {
            warning = "Capture status is not yet available. Open Diagnostics to check the helper."
        }

        if !state.hasLoadedArchive && state.archiveLoadError == nil {
            status = "Loading the library…"; symbol = "clock"
        } else if !state.captureSettings.captureEnabled {
            status = "Capture is off"; symbol = "pause.circle"
        } else if state.captureSettings.isPaused {
            status = "Capture is paused"; symbol = "pause.circle"
        } else if state.helperIsRunning {
            status = "Capture helper is running"; symbol = "waveform.badge.mic"
        } else {
            status = "Capture helper is not running"; symbol = "exclamationmark.circle"
        }
    }

    init(status: String, symbol: String = "waveform.badge.mic", warning: String? = nil,
         recordingCount: Int = 0, lastArchived: Date? = nil, lastScan: Date? = nil, latestRecordID: String? = nil) {
        self.status = status; self.symbol = symbol; self.warning = warning
        self.recordingCount = recordingCount; self.lastArchived = lastArchived
        self.lastScan = lastScan; self.latestRecordID = latestRecordID
    }
}

struct DictationStatusCard: View {
    @ObservedObject var state: AppState
    var open: () -> Void
    var settings: () -> Void
    var latest: (String) -> Void
    var dismiss: () -> Void

    var body: some View {
        DictationStatusCardContent(summary: DictationCardSummary(state: state), open: open,
                                   settings: settings, latest: latest, floatingLog: state.openDictationLog)
            .onExitCommand(perform: dismiss)
    }
}

struct DictationStatusCardContent: View {
    let summary: DictationCardSummary
    var open: () -> Void
    var settings: () -> Void
    var latest: (String) -> Void
    var floatingLog: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "mic.square.fill").font(.title2).accessibilityHidden(true)
                Text("Codex Dictation Console").font(.headline)
                Spacer(minLength: 4)
                Button(action: settings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open Settings")
                    .help("Settings")
            }
            Label(summary.status, systemImage: summary.symbol)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            VStack(spacing: 8) {
                row("Archived recordings", value: summary.recordingCount.formatted())
                row("Last archived", value: date(summary.lastArchived))
                row("Last scan", value: date(summary.lastScan))
            }
            .font(.callout)
            Text(summary.warning ?? "Recordings stay on this Mac. Transcripts are shown in the library.")
                .font(.caption)
                .foregroundStyle(summary.warning == nil ? .secondary : Color.orange)
                .lineLimit(3, reservesSpace: true)
                .help(summary.warning ?? "Your archive is private and local.")
            Button("Open latest recording") {
                if let id = summary.latestRecordID { latest(id) }
            }
            .disabled(summary.latestRecordID == nil)
            Button("Open floating dictation log", action: floatingLog)
            Divider()
            Button(action: open) {
                Text("Open Codex Dictation Console").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func date(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet available"
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).lineLimit(1).minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }
}
