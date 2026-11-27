import Foundation

extension Calendar {
    /// Gregorian in UTC, so day and hour boundaries don't depend on the machine running the tests.
    static var utc: Calendar { calendar(in: "UTC") }

    static func calendar(in timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }
}
