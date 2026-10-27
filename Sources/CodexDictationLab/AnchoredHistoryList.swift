import AppKit
import DictationArchiveCore
import SwiftUI

/// Keeps the first visible recording at the same pixel offset during archive updates.
/// A row ID alone cannot preserve a position partway through a row.
struct AnchoredHistoryList<RowContent: View>: NSViewRepresentable {
    let records: [ArchivedDictationRecord]
    @Binding var selectedID: String?
    let filterKey: String
    var positionGroup = "results"
    var scrollRequest: HistoryScrollRequest?
    var rowHeight: CGFloat = 76
    @ViewBuilder var rowContent: (ArchivedDictationRecord) -> RowContent

    func makeCoordinator() -> Coordinator {
        Coordinator(rowContent: rowContent)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let selection = $selectedID
        context.coordinator.onSelection = { selection.wrappedValue = $0 }
        context.coordinator.rowContent = rowContent
        context.coordinator.update(
            records: records, selectedID: selectedID, filterKey: filterKey,
            positionGroup: positionGroup, scrollRequest: scrollRequest, rowHeight: rowHeight
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let scrollView = NSScrollView()
        let tableView = NSTableView()
        private(set) var records: [ArchivedDictationRecord] = []
        var rowContent: (ArchivedDictationRecord) -> RowContent
        var onSelection: ((String?) -> Void)?
        private var filterKey: String?
        private var positionGroup: String?
        private var savedPositions: [String: (filterKey: String, id: String, offset: CGFloat)] = [:]
        private var handledScrollRequest: UUID?
        private var isUpdating = false
        private let cellID = NSUserInterfaceItemIdentifier("recording")

        init(rowContent: @escaping (ArchivedDictationRecord) -> RowContent) {
            self.rowContent = rowContent
            super.init()

            let column = NSTableColumn(identifier: cellID)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.style = .inset
            tableView.rowHeight = 76
            tableView.usesAutomaticRowHeights = false
            tableView.intercellSpacing = .zero
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.dataSource = self
            tableView.delegate = self
            tableView.setAccessibilityLabel("Dictation recordings")

            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.contentView = HistoryClipView()
            scrollView.documentView = tableView
        }

        func update(
            records newRecords: [ArchivedDictationRecord], selectedID: String?, filterKey: String,
            positionGroup: String = "results", scrollRequest: HistoryScrollRequest? = nil,
            rowHeight: CGFloat = 76
        ) {
            let filterChanged = self.filterKey != filterKey
            let groupChanged = self.positionGroup != positionGroup
            if groupChanged, let oldGroup = self.positionGroup, let oldFilter = self.filterKey,
               let position = visibleAnchor(survivingIDs: Set(records.map(\.id))) {
                savedPositions[oldGroup] = (oldFilter, position.id, position.offset)
            }
            let saved = groupChanged ? savedPositions[positionGroup] : nil
            let restored = saved?.filterKey == filterKey ? saved : nil
            let identitiesChanged = records.map(\.id) != newRecords.map(\.id)
            let rowHeightChanged = tableView.rowHeight != rowHeight
            let anchor: (id: String, offset: CGFloat)? = restored.map { ($0.id, $0.offset) }
                ?? (filterChanged ? nil : visibleAnchor(survivingIDs: Set(newRecords.map(\.id))))
            let requestedRow = scrollRequest.flatMap { request in
                request.id != handledScrollRequest ? newRecords.firstIndex { $0.id == request.recordID } : nil
            }
            isUpdating = true
            defer { isUpdating = false }

            let oldRecords = records
            records = newRecords
            self.filterKey = filterKey
            self.positionGroup = positionGroup
            tableView.rowHeight = rowHeight
            if identitiesChanged || groupChanged || rowHeightChanged {
                tableView.reloadData()
            } else if oldRecords != newRecords {
                // Fixed-height rows can change text/status without invalidating scroll geometry.
                let changedRows = IndexSet(newRecords.indices.filter { oldRecords[$0] != newRecords[$0] })
                tableView.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
            }

            let selection = newRecords.firstIndex { $0.id == selectedID }.map { IndexSet(integer: $0) } ?? []
            if tableView.selectedRowIndexes != selection {
                tableView.selectRowIndexes(selection, byExtendingSelection: false)
            }

            if filterChanged || groupChanged || identitiesChanged || rowHeightChanged || requestedRow != nil {
                scrollView.layoutSubtreeIfNeeded()
                tableView.layoutSubtreeIfNeeded()
                let centeredY = requestedRow.map {
                    tableView.rect(ofRow: $0).midY - scrollView.contentView.bounds.height / 2
                }
                let y = centeredY ?? anchor.flatMap { anchor in
                    newRecords.firstIndex { $0.id == anchor.id }.map {
                        tableView.rect(ofRow: $0).minY - anchor.offset
                    }
                } ?? (filterChanged ? 0 : scrollView.contentView.bounds.minY)
                let maxY = max(0, tableView.frame.height - scrollView.contentView.bounds.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                if requestedRow != nil { handledScrollRequest = scrollRequest?.id }
                // Restore synchronously: a queued restoration could undo the user's next scroll.
            }
        }

        private func visibleAnchor(survivingIDs: Set<String>) -> (id: String, offset: CGFloat)? {
            let bounds = scrollView.contentView.bounds
            let visibleRows = tableView.rows(in: bounds)
            guard visibleRows.location != NSNotFound else { return nil }
            for row in visibleRows.location..<NSMaxRange(visibleRows) where records.indices.contains(row) {
                if survivingIDs.contains(records[row].id) {
                    return (records[row].id, tableView.rect(ofRow: row).minY - bounds.minY)
                }
            }
            return nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { records.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let content = rowContent(records[row])
            if let cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSHostingView<RowContent> {
                cell.rootView = content
                return cell
            }
            let cell = NSHostingView(rootView: content)
            cell.identifier = cellID
            cell.sizingOptions = []
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            let row = tableView.selectedRow
            onSelection?(records.indices.contains(row) ? records[row].id : nil)
        }
    }
}

private final class HistoryClipView: NSClipView {
    override func setFrameSize(_ newSize: NSSize) {
        let origin = bounds.origin
        super.setFrameSize(newSize)
        // AppKit can round the current row offset while resizing the viewport.
        // Keep the original position, subject to the new document bounds.
        scroll(to: origin)
    }
}
