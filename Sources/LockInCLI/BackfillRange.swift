import Foundation

/// Reads a backfill range, such as `9:00-10:30`, `22:30-01:15`, `23:00-now` or `2026-11-03T22:30-2026-11-04T01:15`.
/// - A range whose end is earlier than its start runs past midnight.
/// - Times without a date mean their most recent occurrence that's entirely in the past.
/// - A date-less end after a dated start is the first time it comes round after the start, and vice versa.
enum BackfillRange {
    private struct Point {
        var day: DateComponents?
        var hour = 0, minute = 0
        var isNow = false
    }

    static func resolve(_ text: String, now: Date, calendar: Calendar = .current) throws -> (start: Date, end: Date) {
        // Dates contain "-" too, so try each "-" until both sides read as times.
        let separators = text.indices.filter { text[$0] == "-" }
        guard let (from, to) = separators.lazy.compactMap({ index -> (Point, Point)? in
            guard let from = point(String(text[..<index])), let to = point(String(text[text.index(after: index)...])), !from.isNow else { return nil }
            return (from, to)
        }).first else {
            throw UsageError("Give a range such as 9:00-10:30, 22:30-01:15, 23:00-now or 2026-11-03T22:30-2026-11-04T01:15.")
        }
        func at(_ point: Point, on day: Date) throws -> Date {
            guard let date = calendar.date(bySettingHour: point.hour, minute: point.minute, second: 0, of: day) else {
                throw UsageError("Couldn't read that time.")
            }
            return date
        }
        func dated(_ point: Point) throws -> Date {
            // date(from:) rolls 2026-02-31 over into March, so check the day survived.
            guard let parts = point.day, let day = calendar.date(from: parts), calendar.component(.day, from: day) == parts.day else {
                throw UsageError("Couldn't read that date.")
            }
            return try at(point, on: day)
        }
        // Identical times would otherwise read as a whole day; that's far more likely a typo.
        if from.hour == to.hour && from.minute == to.minute && !to.isNow && (from.day == nil || to.day == nil) {
            throw UsageError("The range starts and ends at the same time.")
        }
        let day = TimeInterval(86_400)
        var start: Date, end: Date
        switch (from.day != nil, to.day != nil || to.isNow) {
        case (true, true):
            start = try dated(from); end = to.isNow ? now : try dated(to)
        case (true, false):
            start = try dated(from); end = try at(to, on: start)
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(day) }
        case (false, true):
            end = to.isNow ? now : try dated(to); start = try at(from, on: end)
            if start >= end { start = calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-day) }
        case (false, false):
            end = try at(to, on: now); start = try at(from, on: end)
            if start >= end { start = calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-day) }
            if end > now {
                end = calendar.date(byAdding: .day, value: -1, to: end) ?? end.addingTimeInterval(-day)
                start = calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-day)
            }
        }
        guard start < end else { throw UsageError("The range ends before it starts.") }
        guard end <= now else { throw UsageError("That range ends in the future.") }
        return (start, end)
    }

    /// "now", "H:MM", or "YYYY-MM-DDTH:MM".
    private static func point(_ text: String) -> Point? {
        if text == "now" { return Point(isNow: true) }
        var point = Point()
        var time = Substring(text)
        if let t = text.firstIndex(of: "T") {
            let date = text[..<t].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard date.count == 3, let y = date[0], let m = date[1], let d = date[2], text[..<t].count == 10 else { return nil }
            point.day = DateComponents(year: y, month: m, day: d)
            time = text[text.index(after: t)...]
        }
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        point.hour = hour; point.minute = minute
        return point
    }
}
