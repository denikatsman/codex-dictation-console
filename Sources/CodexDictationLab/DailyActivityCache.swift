import DictationArchiveCore
import Foundation

/// Owns only 30 aggregate rows, never a second copy of the archive records.
@MainActor
final class DailyActivityCache {
    private struct CalendarKey: Equatable {
        let day: Date
        let identifier: Calendar.Identifier
        let timeZone: String
        let offset: Int
        let locale: String?

        init(now: Date, calendar: Calendar) {
            day = calendar.startOfDay(for: now)
            identifier = calendar.identifier
            timeZone = calendar.timeZone.identifier
            offset = calendar.timeZone.secondsFromGMT(for: now)
            locale = calendar.locale?.identifier
        }
    }
    private var calendarKey: CalendarKey?
    private var recordsRevision: UInt64?
    private var rows: [DailyArchiveActivity] = []
    private(set) var computationCount = 0

    func invalidateCalendarIfChanged(now: Date, calendar: Calendar) -> Bool {
        guard let calendarKey, calendarKey != CalendarKey(now: now, calendar: calendar) else { return false }
        self.calendarKey = nil
        recordsRevision = nil
        return true
    }

    func value(records: [ArchivedDictationRecord], revision: UInt64, now: Date, calendar: Calendar) -> [DailyArchiveActivity] {
        let key = CalendarKey(now: now, calendar: calendar)
        if calendarKey == key, recordsRevision == revision { return rows }
        let start = calendar.date(byAdding: .day, value: -29, to: key.day) ?? key.day
        let grouped = Dictionary(grouping: records.filter { $0.createdAt >= start }) {
            calendar.startOfDay(for: $0.createdAt)
        }
        rows = (0..<30).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let records = grouped[day] ?? []
            return DailyArchiveActivity(day: day,
                durationSeconds: ArchiveDuration.total(records.map(\.durationSeconds)), recordingCount: records.count)
        }
        calendarKey = key
        recordsRevision = revision
        computationCount += 1
        return rows
    }
}
