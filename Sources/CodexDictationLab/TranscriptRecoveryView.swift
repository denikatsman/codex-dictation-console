import DictationArchiveCore
import Foundation
import SwiftUI

@MainActor
final class TranscriptRecoveryModel: ObservableObject {
    enum Provider { case macOS, codex }
    @Published private(set) var activeRecordID: String?
    @Published private(set) var progress = ""
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var revision: UInt64 = 0
    private let store: ArchiveStore
    private var task: Task<Void, Never>?

    init(store: ArchiveStore) { self.store = store }

    func recover(_ record: ArchivedDictationRecord, localeIdentifier: String, provider: Provider = .macOS) {
        guard task == nil else { return }
        activeRecordID = record.id
        errors[record.id] = nil
        progress = "Preparing recovery…"
        // AppState owns this model, so changing recordings or closing the
        // library window does not discard work or its eventual saved text.
        task = Task {
            do {
                let update: @Sendable (String) async -> Void = { message in
                    await self.setProgress(message)
                }
                switch provider {
                case .macOS:
                    _ = try await LocalTranscriptRecovery(store: store).recover(recordID: record.id, locale: Locale(identifier: localeIdentifier), progress: update)
                case .codex:
                    _ = try await CodexTranscriptRecovery(store: store).recover(recordID: record.id, localeIdentifier: localeIdentifier, progress: update)
                }
                revision &+= 1
            } catch where Task.isCancelled || error is CancellationError {
                errors[record.id] = "Recovery cancelled. The saved audio is still available."
            } catch {
                errors[record.id] = error.localizedDescription
            }
            activeRecordID = nil
            task = nil
        }
    }

    private func setProgress(_ message: String) { progress = message }
    func cancel() { task?.cancel() }
}

struct TranscriptRecoveryView: View {
    let record: ArchivedDictationRecord
    @ObservedObject var model: TranscriptRecoveryModel
    @AppStorage("transcriptRecovery.localeIdentifier") private var localeIdentifier = "en_US"
    @State private var locales: [Locale] = []
    @State private var recoveries: [RecoveredTranscript] = []
    @State private var selectedAttempt = 0
    @State private var readError: String?

    private var recovered: RecoveredTranscript? {
        recoveries.indices.contains(selectedAttempt) ? recoveries[selectedAttempt] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recovered {
                HStack {
                    Text("Recovered transcript").font(.headline)
                    Spacer()
                    Button("Copy recovered text") { copyToPasteboard(recovered.text) }
                }
                if recoveries.count > 1 {
                    Picker("Saved attempts", selection: $selectedAttempt) {
                        ForEach(recoveries.indices, id: \.self) { index in
                            let attempt = recoveries[index]
                            Text("\(recoveries.count - index) · \(attempt.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(languageName(attempt.localeIdentifier)) · \(attempt.engine)")
                                .tag(index)
                        }
                    }
                    .accessibilityIdentifier("recovery.attempts")
                }
                Text("\(languageName(recovered.localeIdentifier)) · \(recovered.engine). Review for recognition errors.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(recovered.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
            if record.hasPlayableAudio || record.transcript.isEmpty {
                Text(recovered == nil ? "Recover from saved audio" : "Transcribe again").font(.headline)
                Text("Every attempt is saved separately. Your original audio and exact transcript are preserved.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Spoken language", selection: $localeIdentifier) {
                    Text("Detect automatically (Codex)").tag("auto")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(languageName(locale.identifier))
                            .tag(locale.identifier)
                    }
                }
                .accessibilityIdentifier("recovery.language")
                .disabled(model.activeRecordID != nil)
                if let active = model.activeRecordID {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(active == record.id ? model.progress : "Recovering another recording…").font(.callout)
                        Spacer()
                        Button("Cancel recovery") { model.cancel() }
                    }
                } else {
                    HStack {
                        Button("Transcribe with macOS") {
                            model.recover(record, localeIdentifier: localeIdentifier)
                        }
                        .accessibilityIdentifier("recovery.transcribe")
                        .disabled(!canTranscribe || !LocalTranscriptRecovery.isAvailable || localeIdentifier == "auto" || locales.isEmpty)
                        Button("Transcribe with Codex") {
                            model.recover(record, localeIdentifier: localeIdentifier, provider: .codex)
                        }
                        .accessibilityIdentifier("recovery.codex")
                        .disabled(!canTranscribe)
                    }
                }
                Text("macOS transcribes on this Mac and may download a language model. Codex uploads this recording to OpenAI using your Codex ChatGPT sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
                if localeIdentifier == "auto" {
                    Text("Choose a spoken language to use macOS transcription.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !LocalTranscriptRecovery.isAvailable {
                    Text(TranscriptRecoveryError.unavailable.localizedDescription)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = model.errors[record.id] ?? readError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .task {
            let supported = await LocalTranscriptRecovery.supportedLocales()
            locales = Array(Set(supported + [Locale(identifier: "en_US"), Locale(identifier: "ru_RU")]))
                // Personal daily-use shortlist; keep full language support available underneath.
                .filter { ["en_US", "ru_RU"].contains($0.identifier) }
                .sorted { $0.identifier < $1.identifier }
            if localeIdentifier != "auto", !locales.contains(where: { $0.identifier == localeIdentifier }) {
                localeIdentifier = "auto"
            }
        }
        .task(id: "\(record.id)-\(record.audioSHA256 ?? "")-\(model.revision)") {
            recoveries = []
            selectedAttempt = 0
            do {
                let attempts = try await Task.detached { try TranscriptRecoveryStore.read(from: record) }.value
                guard !Task.isCancelled else { return }
                recoveries = attempts
                readError = nil
            } catch {
                guard !Task.isCancelled else { return }
                recoveries = []
                readError = error.localizedDescription
            }
        }
    }

    private func languageName(_ identifier: String) -> String {
        if identifier == "auto" { return "Automatic language detection" }
        return Locale.autoupdatingCurrent.localizedString(forIdentifier: identifier) ?? identifier
    }

    private var canTranscribe: Bool { record.hasPlayableAudio && record.status != "recording" }
}
