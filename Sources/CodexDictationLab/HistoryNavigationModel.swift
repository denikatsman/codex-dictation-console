import DictationArchiveCore
import Foundation

struct HistoryScrollRequest: Equatable {
    let id = UUID()
    let recordID: String
}

struct RecordingContext {
    let anchor: ArchivedDictationRecord
    var earlierCount = 3
    var laterCount = 3

    func window(in newestFirstRecords: [ArchivedDictationRecord]) -> RecordingContextWindow {
        // Use the archive's existing stable order, reversed for reading forwards.
        // Search terms and source filters never limit temporal context.
        let ordered = Array(newestFirstRecords.filter { !$0.isDeleted }.reversed())
        guard let index = ordered.firstIndex(where: { $0.id == anchor.id }) else {
            return RecordingContextWindow(records: [], hasEarlier: false, hasLater: false)
        }
        let lower = max(0, index - earlierCount)
        let upper = min(ordered.count, index + laterCount + 1)
        return RecordingContextWindow(
            records: Array(ordered[lower..<upper]),
            hasEarlier: lower > 0,
            hasLater: upper < ordered.count
        )
    }

    static func relativeTime(_ date: Date, to anchor: Date) -> String {
        let interval = date.timeIntervalSince(anchor)
        guard abs(interval) >= 0.5 else { return "Same time" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        let duration = formatter.string(from: abs(interval).rounded()) ?? "Less than a second"
        return "\(duration) \(interval < 0 ? "earlier" : "later")"
    }
}

struct RecordingContextWindow {
    let records: [ArchivedDictationRecord]
    let hasEarlier: Bool
    let hasLater: Bool
}

@MainActor
final class HistoryNavigationModel: ObservableObject {
    @Published var searchText = ""
    @Published var surfaceFilter: SurfaceFilter = .all
    @Published private(set) var context: RecordingContext?
    @Published private(set) var scrollRequest: HistoryScrollRequest?
    var onSelection: ((String?) -> Void)?

    func showContext(around record: ArchivedDictationRecord) {
        context = RecordingContext(anchor: record)
        onSelection?(record.id)
        scrollTo(record.id)
    }

    func showMoreEarlier() { context?.earlierCount += 3 }
    func showMoreLater() { context?.laterCount += 3 }

    @discardableResult
    func returnToResults() -> String? {
        let originalID = context?.anchor.id
        context = nil
        if let originalID { onSelection?(originalID) }
        return originalID
    }

    func showFullHistory(_ recordID: String) {
        context = nil
        searchText = ""
        surfaceFilter = .all
        onSelection?(recordID)
        scrollTo(recordID)
    }

    func scrollTo(_ recordID: String) {
        scrollRequest = HistoryScrollRequest(recordID: recordID)
    }
}

enum SurfaceFilter: String, CaseIterable, Identifiable {
    case all
    case composer
    case global

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .composer: "Composer"
        case .global: "Global"
        }
    }
    var surface: DictationSurface? {
        switch self {
        case .all: nil
        case .composer: .composer
        case .global: .global
        }
    }
}
