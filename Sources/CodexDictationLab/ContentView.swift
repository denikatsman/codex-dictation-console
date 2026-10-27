import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $state.section) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("Codex Dictation Console")
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 7) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(.secondary)
                    Text("Private, local archive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        } detail: {
            Group {
                switch state.section {
                case .overview:
                    OverviewView()
                case .history:
                    HistoryView()
                case .diagnostics:
                    DiagnosticsView()
                case .settings:
                    SettingsView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = state.archiveLoadError {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.hasLoadedArchive ? "The archive could not refresh. Showing the last loaded recordings." : "The archive could not be opened.")
                                .fontWeight(.medium)
                            Text(error).font(.caption).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.07))
                }
            }
            .toolbar {
                ToolbarItem {
                    Button(action: state.openDictationLog) { Image(systemName: "text.bubble") }
                        .help("Open floating log of the latest 10 dictations (⇧⌘L)")
                        .accessibilityLabel("Open floating dictation log")
                        .accessibilityIdentifier("dictation.log.open")
                }
                if state.isExporting {
                    ToolbarItem {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…").font(.caption)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                ToolbarItem {
                    Button {
                        Task { await state.refreshAll() }
                    } label: {
                        if state.isLoadingArchive || state.isVerifyingArchive || state.isRefreshingUsage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(state.isLoadingArchive || state.isVerifyingArchive || state.isRefreshingUsage)
                    .accessibilityLabel("Refresh archive and account usage")
                    .help(state.isVerifyingArchive ? "Verifying archived files" : "Capture new recordings and refresh")
                }
            }
        }
        .alert("Codex Dictation Console", isPresented: alertBinding) {
            Button("OK", role: .cancel) {
                state.alertMessage = nil
            }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { state.alertMessage != nil },
            set: { visible in
                if !visible { state.alertMessage = nil }
            }
        )
    }
}
