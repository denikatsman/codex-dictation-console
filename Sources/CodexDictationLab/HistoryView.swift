import AppKit
import DictationArchiveCore
import SwiftUI

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var search = ArchiveSearchModel()
    @StateObject private var navigation: HistoryNavigationModel

    init(navigation: HistoryNavigationModel? = nil) {
        _navigation = StateObject(wrappedValue: navigation ?? HistoryNavigationModel())
    }

    private var contextWindow: RecordingContextWindow? {
        navigation.context?.window(in: state.records)
    }

    private var visibleRecords: [ArchivedDictationRecord] {
        contextWindow?.records ?? filteredRecords
    }

    private var resultsFilterKey: String {
        navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{0}" + navigation.surfaceFilter.rawValue
    }

    private var listFilterKey: String {
        navigation.context.map { "context:\($0.anchor.id)" } ?? resultsFilterKey
    }

    private var filteredRecords: [ArchivedDictationRecord] {
        let query = navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingIDs = Set(search.query == query ? search.results.map(\.id) : [])
        let candidates = query.isEmpty ? state.records : state.records.filter { matchingIDs.contains($0.id) }
        return candidates.filter { record in
            let surfaceMatches = navigation.surfaceFilter.surface.map { $0 == record.surface } ?? true
            return surfaceMatches
        }
    }

    private var selectedRecord: ArchivedDictationRecord? {
        state.records.first(where: { $0.id == state.selectedRecordID })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Dictation history",
                detail: "Search exact transcripts, replay the original audio, or export a complete record"
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            HSplitView {
                transcriptList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                Group {
                    if let selectedRecord {
                        RecordingDetailView(
                            record: selectedRecord,
                            showsContext: navigation.context == nil,
                            showContext: { showContext(selectedRecord) },
                            showFullHistory: { showFullHistory(selectedRecord.id) }
                        )
                            .id(selectedRecord.id)
                    } else {
                        EmptyPanel(
                            title: "Select a recording",
                            detail: "Choose an archived dictation to see its transcript and audio.",
                            symbol: "waveform"
                        )
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            let appState = state
            navigation.onSelection = { [weak appState] in appState?.selectedRecordID = $0 }
            ensureSelection()
        }
        .onChange(of: state.records.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: visibleRecords.map(\.id)) { _, _ in ensureSelection() }
        .task(id: searchTaskID) {
            let query = navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            await search.search(query) { await state.searchArchive($0) }
        }
    }

    private var transcriptList: some View {
        VStack(spacing: 0) {
            if let context = navigation.context {
                contextControls(context)
            } else {
                searchControls
            }

            Divider()

            if let window = contextWindow {
                contextBoundary(earlier: true, hasMore: window.hasEarlier)
            }

            HistoryResultsView(
                records: visibleRecords,
                selectedID: $state.selectedRecordID,
                filterKey: listFilterKey,
                isSearching: navigation.context == nil && search.isSearching,
                archiveIsEmpty: state.records.isEmpty,
                isLoadingArchive: !state.hasLoadedArchive && state.archiveLoadError == nil,
                archiveLoadError: state.archiveLoadError,
                contextAnchor: navigation.context?.anchor,
                scrollRequest: navigation.scrollRequest,
                showContext: { showContext($0) },
                showFullHistory: { showFullHistory($0) }
            ) { id in
                Task { await state.moveToRecentlyDeleted(id: id) }
            }

            if let window = contextWindow {
                contextBoundary(earlier: false, hasMore: window.hasLater)
            }

            Divider()
            archiveFooter
        }
    }

    private var searchControls: some View {
        VStack(spacing: 0) {
            // History is already in the outer navigation split's detail column.
            // Keep search in this pane instead of relying on sidebar placement.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search exact transcripts", text: $navigation.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search exact transcripts")
                if !navigation.searchText.isEmpty {
                    Button {
                        navigation.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
                    .help("Clear search")
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Picker("Surface", selection: $navigation.surfaceFilter) {
                ForEach(SurfaceFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

        }
    }

    private func contextControls(_ context: RecordingContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: returnToResults) {
                Label(navigation.searchText.isEmpty ? "Back to history" : "Back to search", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("history.backToResults")
            Text("Surrounding dictations")
                .font(.headline)
            Text("All sources · oldest first")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                state.selectedRecordID = context.anchor.id
                navigation.scrollTo(context.anchor.id)
            } label: {
                Label("Original: \(LabFormatting.dateTime(context.anchor.createdAt))", systemImage: "scope")
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help("Select and reveal the original recording")
            .accessibilityIdentifier("history.originalRecording")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func contextBoundary(earlier: Bool, hasMore: Bool) -> some View {
        Group {
            if hasMore {
                Button(earlier ? "Show more earlier" : "Show more later") {
                    if earlier { navigation.showMoreEarlier() }
                    else { navigation.showMoreLater() }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(earlier ? "history.moreEarlier" : "history.moreLater")
            } else {
                Text(earlier ? "Start of saved history" : "End of saved history")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var archiveFooter: some View {
        HStack {
            Text("\(visibleRecords.count) of \(state.records.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if navigation.context == nil && search.isSearching && !filteredRecords.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing search results")
            }
            Spacer()
            Button {
                Task { await state.refreshArchive(scanSource: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(state.isLoadingArchive || state.isVerifyingArchive)
            .accessibilityLabel("Capture and refresh archive")
            .help("Capture and refresh")
            Button {
                state.revealArchive()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show archive in Finder")
            .help("Show archive")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func ensureSelection() {
        if let context = navigation.context, !state.records.contains(where: { $0.id == context.anchor.id }) {
            returnToResults()
        }
        if let selectedID = state.selectedRecordID, visibleRecords.contains(where: { $0.id == selectedID }) { return }
        state.selectedRecordID = navigation.context?.anchor.id ?? visibleRecords.first?.id
    }

    private func returnToResults() {
        navigation.returnToResults()
    }

    private func showContext(_ record: ArchivedDictationRecord) {
        navigation.showContext(around: record)
    }

    private func showFullHistory(_ id: String) {
        navigation.showFullHistory(id)
    }

    private var searchTaskID: String {
        "\(navigation.searchText)\u{0}\(state.recordsRevision)"
    }
}

struct HistoryResultsView: View {
    let records: [ArchivedDictationRecord]
    @Binding var selectedID: String?
    let filterKey: String
    let isSearching: Bool
    let archiveIsEmpty: Bool
    var isLoadingArchive = false
    var archiveLoadError: String?
    var contextAnchor: ArchivedDictationRecord?
    var scrollRequest: HistoryScrollRequest?
    var showContext: ((ArchivedDictationRecord) -> Void)?
    var showFullHistory: ((String) -> Void)?
    let moveToRecentlyDeleted: (String) -> Void

    var body: some View {
        ZStack {
            AnchoredHistoryList(
                records: records, selectedID: $selectedID, filterKey: filterKey,
                positionGroup: contextAnchor == nil ? "results" : "context",
                scrollRequest: scrollRequest, rowHeight: contextAnchor == nil ? 76 : 100
            ) { record in
                RecordingListRow(record: record, contextAnchor: contextAnchor)
                    .contextMenu {
                        if contextAnchor == nil, let showContext {
                            Button("Show in Context") { showContext(record) }
                        }
                        if let showFullHistory {
                            Button("Show in Full History") { showFullHistory(record.id) }
                        }
                        Divider()
                        Button("Copy Transcript") { copyToPasteboard(record.transcript) }
                            .disabled(record.transcript.isEmpty)
                        Button("Show Archived Files") {
                            NSWorkspace.shared.activateFileViewerSelecting([record.archiveFolderURL])
                        }
                        Divider()
                        Button("Move to Recently Deleted", role: .destructive) {
                            moveToRecentlyDeleted(record.id)
                        }
                    }
            }
            .opacity(records.isEmpty ? 0 : 1)

            // Keep the scroll view mounted even while a query is loading or empty.
            if records.isEmpty {
                if let archiveLoadError {
                    EmptyPanel(title: "Archive unavailable", detail: archiveLoadError, symbol: "exclamationmark.triangle")
                } else if isLoadingArchive {
                    ProgressView("Loading recordings…")
                } else if isSearching {
                    ProgressView("Searching transcripts…")
                } else {
                    EmptyPanel(
                        title: archiveIsEmpty ? "Nothing archived yet" : "No matching recordings",
                        detail: archiveIsEmpty
                            ? "The capture helper will save your next Codex dictation here."
                            : "Change the search or source filter.",
                        symbol: archiveIsEmpty ? "waveform" : "magnifyingglass"
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct RecordingListRow: View {
    let record: ArchivedDictationRecord
    var contextAnchor: ArchivedDictationRecord?

    private var isOriginal: Bool { contextAnchor?.id == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let anchor = contextAnchor {
                HStack {
                    if isOriginal {
                        Label("Original match", systemImage: "scope")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(RecordingContext.relativeTime(record.createdAt, to: anchor.createdAt))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(record.createdAt, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            Text(record.transcript.isEmpty ? "No transcript text" : record.transcript)
                .font(.callout)
                // Placeholder and completed transcripts occupy the same two lines.
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(record.transcript.isEmpty ? .secondary : .primary)
            HStack(spacing: 7) {
                Image(systemName: record.surface.symbol)
                Text(record.surface.title)
                Text(LabFormatting.duration(record.durationSeconds))
                if record.status != "completed" {
                    Text(record.status.capitalized)
                }
                if record.isPartial {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Some source audio or metadata is incomplete or could not be verified")
                }
                Spacer(minLength: 4)
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isOriginal ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct RecordingDetailView: View {
    @EnvironmentObject private var state: AppState
    let record: ArchivedDictationRecord
    let showsContext: Bool
    let showContext: () -> Void
    let showFullHistory: () -> Void
    @State private var copied = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LabFormatting.dateTime(record.createdAt))
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 10) {
                            Label(record.surface.title, systemImage: record.surface.symbol)
                            Label(record.status.capitalized, systemImage: statusSymbol)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actionButtons
                }

                HStack(spacing: 12) {
                    if showsContext {
                        Button("Show in context", action: showContext)
                            .accessibilityIdentifier("history.showContext")
                    }
                    Button("Show in full history", action: showFullHistory)
                        .accessibilityIdentifier("history.showFullHistory")
                }
                .buttonStyle(.borderless)
                .font(.callout)

                audioSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("Exact transcript")
                        .font(.headline)
                    Text(record.transcript.isEmpty ? "No transcript text was saved." : record.transcript)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .padding(16)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(.separator, lineWidth: 1)
                        }
                }

                TranscriptRecoveryView(record: record, model: state.transcriptRecovery)

                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Recording")
                            .font(.headline)
                        LabeledContent("Duration", value: LabFormatting.duration(record.durationSeconds))
                        LabeledContent("Words", value: record.wordCount.formatted())
                        LabeledContent("Characters", value: record.characterCount.formatted())
                        if let pace = record.wordsPerMinute {
                            LabeledContent("Speaking pace", value: "\(pace) wpm")
                        }
                        LabeledContent("Audio size", value: LabFormatting.bytes(record.audioSizeBytes))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Archive integrity")
                            .font(.headline)
                        Label(
                            record.isPartial ? record.partialCaptureTitle : "Complete source capture",
                            systemImage: record.isPartial
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(record.isPartial ? .orange : .green)
                        LabeledContent(
                            "Expected bytes",
                            value: record.expectedSizeBytes.map(LabFormatting.bytes) ?? "Not reported"
                        )
                        LabeledContent("Captured bytes", value: LabFormatting.bytes(record.audioSizeBytes))
                        if let hash = record.audioSHA256 {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Audio SHA-256")
                                    .foregroundStyle(.secondary)
                                Text(hash)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: 850, alignment: .leading)
        }
        .alert("Move this recording to Recently Deleted?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Recently Deleted", role: .destructive) {
                Task { await state.moveToRecentlyDeleted(id: record.id) }
            }
        } message: {
            Text("Only the app’s archived copy will move. Codex’s source history is never changed. You can restore this recording later.")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                copyToPasteboard(record.transcript)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .help(copied ? "Copied" : "Copy transcript")
            .accessibilityLabel(copied ? "Transcript copied" : "Copy transcript")
            .disabled(record.transcript.isEmpty)

            Button { chooseExportDirectory() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Export transcript, audio, metadata, and checksums")
            .accessibilityLabel("Export recording")
            .disabled(state.isExporting)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([record.archiveFolderURL])
            } label: {
                Image(systemName: "folder")
            }
            .help("Show archived files")
            .accessibilityLabel("Show archived files in Finder")

            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .help("Move to Recently Deleted")
            .accessibilityLabel("Move recording to Recently Deleted")
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio recording")
                .font(.headline)
            if record.hasPlayableAudio {
                NativeAudioPlayerView(
                    recordID: record.id,
                    audioURL: record.audioURL,
                    sourceSHA256: record.audioSHA256
                )
                .id(record.audioSHA256 ?? record.updatedAt.description)
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.separator, lineWidth: 1)
                }
                if record.isPartial {
                    Label(
                        record.partialCaptureExplanation,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                Label("No audio bytes were available for this record.", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
        }
    }

    private var statusSymbol: String {
        switch record.status {
        case "completed": "checkmark.circle"
        case "cancelled": "xmark.circle"
        case "recording": "record.circle"
        default: "info.circle"
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the complete recording package."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            if let folder = await state.export(recordID: record.id, to: destination) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
