import Combine
import DictationArchiveCore
import Foundation

struct DictationLogEntry: Equatable, Identifiable, Sendable {
    let id: String
    let recordedAt: Date
    let timestamp: String
    let text: String
    let recovered: Bool
    let partial: Bool

    static func load(store: ArchiveStore, timeZone: TimeZone = .autoupdatingCurrent) throws -> [Self] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd  ·  HH:mm:ss.SSS XXX"
        return try store.latestFinishedRecords().map { record in
            var text = record.transcript
            var recovered = false
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let attempt = try? TranscriptRecoveryStore.read(from: record).first,
               !attempt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = attempt.text
                recovered = true
            }
            return Self(id: record.id, recordedAt: record.createdAt, timestamp: formatter.string(from: record.createdAt),
                text: text, recovered: recovered, partial: record.isPartial)
        }
    }
}

/// Only the ten displayed entries and UI subscriptions. No capture worker,
/// archive writer, polling timer, or second AppState exists for this window.
@MainActor
final class RecentDictationsLogModel: ObservableObject {
    @Published private(set) var entries: [DictationLogEntry] = []
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false
    private let load: @Sendable () throws -> [DictationLogEntry]
    private var refreshTask: Task<Void, Never>?
    private var pending = false
    private var active = false
    private var generation = 0
    private var subscriptions = Set<AnyCancellable>()
    private var distributedObserver: NSObjectProtocol?
    private var calendarObserver: NSObjectProtocol?

    init(store: ArchiveStore, load: (@Sendable () throws -> [DictationLogEntry])? = nil) {
        self.load = load ?? { try DictationLogEntry.load(store: store) }
    }

    func start(state: AppState) {
        guard !active else { refresh(); return }
        active = true
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: ArchiveStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        calendarObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        state.$recordsRevision.dropFirst().sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        state.$captureHealth.dropFirst().sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    func stop() {
        active = false
        generation += 1
        pending = false
        refreshTask?.cancel()
        refreshTask = nil
        subscriptions.removeAll()
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
        if let calendarObserver { NotificationCenter.default.removeObserver(calendarObserver) }
        distributedObserver = nil
        calendarObserver = nil
    }

    func refresh() {
        guard active else { return }
        pending = true
        guard refreshTask == nil else { return }
        let current = generation
        refreshTask = Task { [weak self, load] in
            while let self, self.active, self.pending, self.generation == current, !Task.isCancelled {
                self.pending = false
                let result = await Task.detached(priority: .userInitiated) { Result { try load() } }.value
                guard self.active, self.generation == current, !Task.isCancelled else { return }
                switch result {
                case .success(let entries):
                    if self.entries != entries { self.entries = entries }
                    if self.error != nil { self.error = nil }
                case .failure(let error):
                    if self.error != error.localizedDescription { self.error = error.localizedDescription }
                }
                if !self.hasLoaded { self.hasLoaded = true }
            }
            if let self, self.generation == current { self.refreshTask = nil }
        }
    }
}
