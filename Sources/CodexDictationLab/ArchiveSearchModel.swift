import DictationArchiveCore
import Foundation

@MainActor
final class ArchiveSearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [ArchivedDictationRecord] = []
    @Published private(set) var isSearching = false

    private let debounce: Duration
    private var generation = UUID()

    init(debounce: Duration = .milliseconds(120)) {
        self.debounce = debounce
    }

    func search(
        _ query: String,
        using lookup: (String) async -> [ArchivedDictationRecord]
    ) async {
        let generation = UUID()
        self.generation = generation
        // Refreshing the same search must leave its visible results in place.
        // Clearing them briefly also clears selection and destroys the reading position.
        if self.query != query { results = [] }
        self.query = query
        isSearching = !query.isEmpty
        defer {
            if self.generation == generation { isSearching = false }
        }
        guard !query.isEmpty else { return }
        do { try await Task.sleep(for: debounce) }
        catch { return }
        let matches = await lookup(query)
        // The database lookup may finish after cancellation or a newer query.
        guard !Task.isCancelled, self.generation == generation else { return }
        results = matches
    }
}
