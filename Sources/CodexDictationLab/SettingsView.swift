import AppKit
import DictationArchiveCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Settings",
                    detail: "Control the background helper, your local archive, and deletion"
                )

                AppAccessControls(settings: state.accessSettings)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Floating dictation log").font(.headline)
                        Text("The latest 10 full dictations and exact recorded times, always above other windows.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open floating log", action: state.openDictationLog)
                }
                Divider()
                captureSettings
                    .disabled(state.isSavingSettings)
                Divider()
                archiveActions
                Divider()
                recentlyDeleted
                Divider()
                privacySection
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Background capture")
                    .font(.title3.weight(.semibold))
                if state.isSavingSettings {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Closing the window keeps capture running. Quit from the app menu, Dock, or menu-bar icon warns you before stopping the whole app, including background capture. Reopening the app uses your saved capture settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "Capture new Codex dictations",
                isOn: Binding(
                    get: { state.captureSettings.captureEnabled },
                    set: { value in Task { await state.setCaptureEnabled(value) } }
                )
            )
            Text("Copies new transcript metadata and audio chunks into the managed archive. It never edits or deletes Codex’s source history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            Toggle(
                "Pause capture",
                isOn: Binding(
                    get: { state.captureSettings.isPaused },
                    set: { value in Task { await state.setPaused(value) } }
                )
            )
            .disabled(!state.captureSettings.captureEnabled)
            Text("Pausing keeps every existing archive file but does not protect new recordings from Codex’s rolling source-history cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { state.loginItemState == .enabled || state.loginItemState == .requiresApproval },
                    set: { value in Task { await state.setLaunchAtLogin(value) } }
                )
            )
            HStack(alignment: .firstTextBaseline) {
                Label(state.loginItemState.title, systemImage: loginItemSymbol)
                    .foregroundStyle(loginItemColor)
                Text(state.loginItemState.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if state.loginItemState == .requiresApproval {
                    Button("Open Login Items") { state.openLoginItemSettings() }
                }
            }
            .padding(.leading, 20)

            HStack {
                Label(
                    state.helperIsRunning ? "Background capture worker is running" : "Background capture worker is not running",
                    systemImage: state.helperIsRunning ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(state.helperIsRunning ? .green : .secondary)
                Spacer()
                if !state.helperIsRunning, state.captureSettings.captureEnabled {
                    Button("Start helper now") {
                        Task { await state.setCaptureEnabled(true) }
                    }
                }
            }
            .padding(13)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var archiveActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Archive")
                .font(.title3.weight(.semibold))
            LabeledContent("Recordings", value: state.statistics.recordingCount.formatted())
            LabeledContent("Stored locally", value: LabFormatting.bytes(state.statistics.archiveSizeBytes))
            LabeledContent("Location") {
                Text("~/Library/Application Support/Codex Dictation Lab/Archive")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Button("Show in Finder") { state.revealArchive() }
                Button(state.isExporting ? "Exporting…" : "Export entire archive…") { chooseBulkExportDirectory() }
                    .disabled(state.records.isEmpty || state.isExporting)
                Button("Open Codex dictation settings") { state.openChatGPTSettings() }
            }
            Text("A full export creates one folder per recording with audio.webm, transcript.txt, the original metadata.json, a checksum manifest, and a root manifest.jsonl.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recentlyDeleted: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recently Deleted")
                        .font(.title3.weight(.semibold))
                    Text("Kept forever until you permanently delete it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.deletedRecords.count.formatted())
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if state.deletedRecords.isEmpty {
                Text("Nothing is waiting for deletion.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(state.deletedRecords.enumerated()), id: \.element.id) { index, record in
                    DeletedRecordingRow(record: record)
                    if index < state.deletedRecords.count - 1 { Divider() }
                }
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Privacy and control")
                .font(.title3.weight(.semibold))
            Label("Everything remains on this Mac. No cloud service, analytics, AI model, or network upload is used for the archive.", systemImage: "lock.shield.fill")
            Label("Deleting here affects only the managed archive. The app never changes Codex’s own history.", systemImage: "hand.raised.fill")
            Label("Token and cost estimates are omitted because no exact per-dictation accounting source is exposed.", systemImage: "equal.circle")
        }
        .font(.callout)
    }

    private var loginItemSymbol: String {
        switch state.loginItemState {
        case .enabled: "checkmark.circle.fill"
        case .requiresApproval: "exclamationmark.triangle.fill"
        case .disabled, .unavailable: "circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private var loginItemColor: Color {
        switch state.loginItemState {
        case .enabled: .green
        case .requiresApproval: .orange
        case .disabled, .unavailable: .secondary
        case .failed: .red
        }
    }

    private func chooseBulkExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export All"
        panel.message = "Choose where to create a complete copy of the archive."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            if let folder = await state.exportAll(to: destination) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }
}

private struct DeletedRecordingRow: View {
    @EnvironmentObject private var state: AppState
    let record: ArchivedDictationRecord
    @State private var confirmingPermanentDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.transcript.isEmpty ? "No transcript text" : record.transcript)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(LabFormatting.dateTime(record.createdAt))
                    Text(LabFormatting.duration(record.durationSeconds))
                    if let deletedAt = record.deletedAt {
                        Text("Deleted \(LabFormatting.relative(deletedAt))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") {
                Task { await state.restore(id: record.id) }
            }
            Button("Delete Permanently", role: .destructive) {
                confirmingPermanentDelete = true
            }
        }
        .padding(.vertical, 5)
        .alert("Permanently delete this recording?", isPresented: $confirmingPermanentDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) {
                Task { await state.permanentlyDelete(id: record.id) }
            }
        } message: {
            Text("Its archived audio, transcript, metadata, and manifest will be removed. This cannot be undone. Codex’s source history will still not be touched.")
        }
    }
}
