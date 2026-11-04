import Foundation

public enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "Week", month = "Month", year = "Year"
    public var id: String { rawValue }
    public var component: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
    /// Charts show days within a week or month, and months within a year.
    public var bucket: Calendar.Component { self == .year ? .month : .day }
}

public struct PhaseTotals: Equatable, Sendable {
    public var seconds: [WorkPhase: Double] = [:]
    public init() {}
    /// Each interval's length, by phase; open intervals count up to `now`.
    public init(_ intervals: [WorkInterval], at now: Date) {
        for item in intervals { seconds[item.kind, default: 0] += item.seconds(at: now) }
    }
    public subscript(_ phase: WorkPhase) -> Double { seconds[phase, default: 0] }
    public var total: Double { seconds.values.reduce(0, +) }
    /// Work and overtime together.
    public var worked: Double { self[.work] + self[.overtime] }
}

public struct HistoryBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let totals: PhaseTotals
    /// Planned work of sessions started within the bucket.
    public let target: Double
}

public struct RhythmCell: Identifiable, Sendable {
    public var id: Int { weekday * 24 + hour }
    public let weekday: Int
    public let hour: Int
    public let seconds: Double
}

/// Read-only aggregations of the work journal. Open intervals count up to `now`; nothing is extrapolated.
public struct WorkStats: Sendable {
    public let sessions: [WorkLog]
    public let now: Date
    public let calendar: Calendar
    public init(sessions: [WorkLog], now: Date, calendar: Calendar = .current) {
        self.sessions = sessions; self.now = now; self.calendar = calendar
    }

    public func range(_ period: HistoryPeriod, offset: Int = 0) -> DateInterval {
        let anchor = calendar.date(byAdding: period.component, value: offset, to: now) ?? now
        return calendar.dateInterval(of: period.component, for: anchor) ?? DateInterval(start: anchor, duration: 0)
    }
    public func day(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
    }

    /// Intervals clipped to `range`; open intervals end at `now`.
    public func intervals(in range: DateInterval) -> [WorkInterval] {
        sessions.flatMap(\.intervals).compactMap { item in
            let start = max(item.start, range.start), end = min(item.end ?? now, range.end, now)
            guard end > start else { return nil }
            var copy = item; copy.start = start; copy.end = end
            return copy
        }
    }
    public func totals(in range: DateInterval) -> PhaseTotals {
        PhaseTotals(intervals(in: range), at: now)
    }
    public func target(in range: DateInterval) -> Double {
        sessions.filter { $0.startedAt >= range.start && $0.startedAt < range.end }.reduce(0) { $0 + $1.targetSeconds }
    }
    /// Events recorded within `range`, in time order.
    public func events(in range: DateInterval) -> [SessionEvent] {
        sessions.flatMap(\.events).filter { $0.at >= range.start && $0.at < range.end }.sorted { $0.at < $1.at }
    }
    public func sessions(in range: DateInterval) -> [WorkLog] {
        sessions.filter { $0.startedAt < range.end && ($0.endedAt ?? now) > range.start }
    }

    public func buckets(_ period: HistoryPeriod, in range: DateInterval) -> [HistoryBucket] {
        var result: [HistoryBucket] = []
        var start = range.start
        while start < range.end, let next = calendar.date(byAdding: period.bucket, value: 1, to: start) {
            let slice = DateInterval(start: start, end: min(next, range.end))
            result.append(HistoryBucket(start: start, end: slice.end, totals: totals(in: slice), target: target(in: slice)))
            start = next
        }
        return result
    }

    /// Work in the preceding period up to the same elapsed point, so a period in progress is compared fairly.
    public func previousWork(_ period: HistoryPeriod, offset: Int = 0) -> Double {
        let current = range(period, offset: offset), previous = range(period, offset: offset - 1)
        let elapsed = min(max(0, min(now, current.end).timeIntervalSince(current.start)), previous.duration)
        return totals(in: DateInterval(start: previous.start, duration: elapsed)).worked
    }

    public func daysWorked(in range: DateInterval) -> Int {
        Set(intervals(in: range).filter(\.kind.isFocused).flatMap { item in
            [calendar.startOfDay(for: item.start), calendar.startOfDay(for: (item.end ?? now).addingTimeInterval(-1))]
        }).count
    }
    public func longestStretch(in range: DateInterval) -> Double {
        intervals(in: range).filter(\.kind.isFocused).map { $0.seconds(at: now) }.max() ?? 0
    }

    /// Work and overtime seconds by weekday (1 = Sunday) and hour of day, split exactly at hour boundaries.
    public func rhythm(in range: DateInterval) -> [RhythmCell] {
        var grid: [Int: Double] = [:]
        for item in intervals(in: range) where item.kind.isFocused {
            var cursor = item.start
            let end = item.end ?? now
            while cursor < end {
                let next = min(calendar.dateInterval(of: .hour, for: cursor)?.end ?? end, end)
                grid[calendar.component(.weekday, from: cursor) * 24 + calendar.component(.hour, from: cursor), default: 0] += next.timeIntervalSince(cursor)
                cursor = next
            }
        }
        return (1...7).flatMap { day in (0..<24).map { RhythmCell(weekday: day, hour: $0, seconds: grid[day * 24 + $0] ?? 0) } }
    }
    public var orderedWeekdays: [Int] { (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 } }

    /// "01:05:09": a countdown, rounded up to the whole second.
    public static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    /// "3h 30m", "3h", "45m", "0m" — rounded to the nearest minute.
    public static func format(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        switch (minutes / 60, minutes % 60) {
        case (0, let m): return "\(m)m"
        case (let h, 0): return "\(h)h"
        case (let h, let m): return "\(h)h \(m)m"
        }
    }
}
