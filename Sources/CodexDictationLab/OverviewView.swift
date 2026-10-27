import Charts
import DictationArchiveCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Your dictation archive",
                    detail: "Every captured transcript and its original audio, stored privately on this Mac"
                )

                captureBanner

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { metricTiles }
                        .frame(minWidth: 756)
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                        spacing: 12
                    ) { metricTiles }
                }

                activitySection

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        recentSection
                        accountSection
                    }
                    .frame(minWidth: 700)

                    VStack(alignment: .leading, spacing: 28) {
                        recentSection
                        accountSection
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1_150, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var metricTiles: some View {
        MetricTile(
            title: "Recordings",
            value: state.statistics.recordingCount.formatted(),
            detail: state.statistics.recordingCount == 0
                ? "Waiting for your first recording"
                : state.statistics.partialCount == 0
                    ? "All captured audio is complete"
                    : "\(state.statistics.partialCount) partial capture\(state.statistics.partialCount == 1 ? "" : "s")",
            symbol: "waveform",
            tint: .blue
        )
        MetricTile(
            title: "Spoken time",
            value: LabFormatting.duration(state.statistics.durationSeconds),
            detail: "From source recording metadata",
            symbol: "timer",
            tint: .orange
        )
        MetricTile(
            title: "Transcript words",
            value: state.statistics.wordCount.formatted(),
            detail: "Stored exactly as Codex produced them",
            symbol: "text.word.spacing",
            tint: .teal
        )
        MetricTile(
            title: "Archive size",
            value: LabFormatting.bytes(state.statistics.archiveSizeBytes),
            detail: "Audio, metadata, checksums, and index",
            symbol: "externaldrive.fill",
            tint: .purple
        )
    }

    private var captureBanner: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: captureSymbol)
                .font(.title2)
                .foregroundStyle(captureColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(captureTitle)
                    .font(.headline)
                Text(captureDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Settings") { state.section = .settings }
        }
        .padding(16)
        .background(captureColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(captureColor.opacity(0.18), lineWidth: 1)
        }
    }

    private var captureTitle: String {
        if !state.captureSettings.captureEnabled { return "Background capture is off" }
        if state.captureSettings.isPaused { return "Capture is paused" }
        if state.captureNeedsAttention { return "Capture needs attention" }
        if state.captureHealth == nil { return "Checking capture…" }
        if state.captureHealth?.sourceAvailable == false { return "Waiting for Codex dictation" }
        if !state.helperIsRunning { return "Protected while this app is open" }
        return "Saving Codex’s available recordings"
    }

    private var captureDetail: String {
        if !state.captureSettings.captureEnabled {
            return "New Codex dictations will not be copied into the permanent archive. Existing recordings remain untouched."
        }
        if state.captureSettings.isPaused {
            return "Existing recordings are safe. Resume capture before Codex rotates older source recordings out of its local history."
        }
        if let error = state.captureHealth?.lastError { return error }
        if state.captureNeedsAttention {
            return state.helperLaunchError ?? "No recent successful scan was reported. The app is attempting to recover background capture."
        }
        if let scan = state.captureHealth?.lastScanAt {
            let process = state.helperIsRunning ? "The background capture worker is running" : "The app is monitoring while open"
            return "\(process). Last checked \(LabFormatting.relative(scan)); Codex source files are never changed."
        }
        return "The first capture scan is starting. Codex source files are never changed."
    }

    private var captureSymbol: String {
        if !state.captureSettings.captureEnabled || state.captureSettings.isPaused { return "pause.circle.fill" }
        if state.captureNeedsAttention { return "exclamationmark.triangle.fill" }
        if state.captureHealth == nil { return "clock" }
        return "checkmark.shield.fill"
    }

    private var captureColor: Color {
        if !state.captureSettings.captureEnabled || state.captureSettings.isPaused { return .orange }
        if state.captureNeedsAttention { return .red }
        if state.captureHealth == nil { return .secondary }
        return .green
    }

    private var activitySection: some View {
        let activity = state.dailyActivity
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last 30 days")
                        .font(.title3.weight(.semibold))
                    Text("Minutes of archived dictation per day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let activeDays = activity.filter { $0.recordingCount > 0 }.count
                Text("\(activeDays) active day\(activeDays == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if activity.contains(where: { !($0.durationSeconds.isFinite) }) {
                Text("Some durations are unavailable; daily totals are incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart(activity.filter { $0.durationSeconds.isFinite }) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Minutes", item.durationSeconds / 60)
                )
                .foregroundStyle(Color.blue.gradient)
                .cornerRadius(3)
                .accessibilityLabel(item.day.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue("\(item.recordingCount) recordings, \(LabFormatting.duration(item.durationSeconds))")
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 170)
        }
        .padding(16)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent recordings")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("View all") { state.section = .history }
                    .buttonStyle(.link)
            }
            if !state.hasLoadedArchive, state.archiveLoadError == nil {
                ProgressView("Loading recordings…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if state.records.isEmpty {
                EmptyPanel(
                    title: state.archiveLoadError == nil ? "Nothing archived yet" : "Archive unavailable",
                    detail: state.archiveLoadError ?? "Your next Codex dictation will appear here with its audio.",
                    symbol: "waveform"
                )
            } else {
                ForEach(Array(state.records.prefix(4).enumerated()), id: \.element.id) { index, record in
                    Button { state.showRecording(id: record.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.transcript.isEmpty ? "No transcript text" : record.transcript)
                                .font(.callout)
                                .lineLimit(2)
                                .foregroundStyle(record.transcript.isEmpty ? .secondary : .primary)
                            HStack(spacing: 8) {
                                Label(record.surface.title, systemImage: record.surface.symbol)
                                Text(LabFormatting.duration(record.durationSeconds))
                                Text(LabFormatting.dateTime(record.createdAt))
                                if record.isPartial {
                                    Label("Partial", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open this recording in History")
                    if index < min(4, state.records.count) - 1 { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex account usage")
                        .font(.title3.weight(.semibold))
                    Text("Not dictation usage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    Task { await state.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.isRefreshingUsage)
                .accessibilityLabel("Refresh Codex account usage")
                .help("Refresh account usage")
            }

            if let error = state.usageError {
                Label("Could not refresh account usage. \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let bucket = state.usage?.codexBucket {
                if let primary = bucket.primary { AccountWindowRow(window: primary) }
                if let secondary = bucket.secondary { AccountWindowRow(window: secondary) }
                if let captured = state.usage?.capturedAt {
                    Text("Last successful snapshot: \(LabFormatting.dateTime(captured))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.isRefreshingUsage {
                ProgressView("Reading account meter")
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text("The Codex account meter is unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("This is the general Codex meter exposed by the local account service. It cannot identify a dictation charge, and its percentages are whole numbers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountWindowRow: View {
    let window: MeterWindowSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LabFormatting.windowName(window.windowDurationMinutes))
                Spacer()
                Text(window.usedPercent.map { "\($0)% used" } ?? "Unavailable")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .font(.callout)
            if let percent = window.usedPercent {
                ProgressView(value: Double(min(percent, 100)), total: 100)
                    .tint(percent >= 90 ? .red : percent >= 70 ? .orange : .blue)
            }
            if let reset = window.resetsAt {
                Text("Resets \(LabFormatting.dateTime(reset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
