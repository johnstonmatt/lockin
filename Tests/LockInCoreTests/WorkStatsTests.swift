import XCTest
@testable import LockInCore

final class WorkStatsTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Wednesday 2026-10-28 00:00 UTC.
    let wednesday = Date(timeIntervalSince1970: 1_793_145_600)
    func at(_ hours: Double, day: Int = 0) -> Date { wednesday.addingTimeInterval(Double(day) * 86_400 + hours * 3600) }

    func log(_ intervals: [(WorkPhase, Double, Double?)], day: Int = 0, target: Double = 4) -> WorkLog {
        var log = WorkLog(todos: [], targetSeconds: target * 3600, now: at(intervals[0].1, day: day))
        log.intervals = intervals.map { WorkInterval(kind: $0.0, start: at($0.1, day: day), end: $0.2.map { at($0, day: day) }) }
        if let end = intervals.last?.2 { log.endedAt = at(end, day: day) }
        return log
    }

    func testOvertimeCountsAsWorkedTime() {
        let sessions = [log([(.work, 9, 10), (.overtime, 10, 11.5)], target: 1)]
        let stats = WorkStats(sessions: sessions, now: at(12), calendar: calendar)
        let day = stats.day(containing: at(10))
        XCTAssertEqual(stats.totals(in: day)[.work], 3600)
        XCTAssertEqual(stats.totals(in: day)[.overtime], 5400)
        XCTAssertEqual(stats.totals(in: day).worked, 9000)
        XCTAssertEqual(stats.daysWorked(in: day), 1)
        XCTAssertEqual(stats.rhythm(in: day).reduce(0) { $0 + $1.seconds }, 9000)
    }
    func testTotalsClipToRangeAndCountOpenIntervalsUntilNow() {
        let sessions = [log([(.work, 9, 11), (.break, 11, 11.25), (.pause, 11.25, 11.5), (.work, 11.5, nil)])]
        let stats = WorkStats(sessions: sessions, now: at(12), calendar: calendar)
        let totals = stats.totals(in: stats.day(containing: at(10)))
        XCTAssertEqual(totals[.work], 2.5 * 3600)
        XCTAssertEqual(totals[.break], 900)
        XCTAssertEqual(totals[.pause], 900)
    }

    func testWorkAcrossMidnightIsSplitBetweenDays() {
        let stats = WorkStats(sessions: [log([(.work, 23, 25)])], now: at(30), calendar: calendar)
        XCTAssertEqual(stats.totals(in: stats.day(containing: at(12)))[.work], 3600)
        XCTAssertEqual(stats.totals(in: stats.day(containing: at(12, day: 1)))[.work], 3600)
        XCTAssertEqual(stats.daysWorked(in: stats.range(.week)), 2)
    }

    func testWeekBucketsStartOnFirstWeekdayAndAttributeTargetToStartDay() {
        let sessions = [log([(.work, 9, 12)], target: 3), log([(.work, 9, 10)], day: 1, target: 2)]
        let stats = WorkStats(sessions: sessions, now: at(18, day: 1), calendar: calendar)
        let buckets = stats.buckets(.week, in: stats.range(.week))
        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(calendar.component(.weekday, from: buckets[0].start), 2)
        XCTAssertEqual(buckets[2].totals[.work], 3 * 3600)
        XCTAssertEqual(buckets[2].target, 3 * 3600)
        XCTAssertEqual(buckets[3].target, 2 * 3600)
        XCTAssertEqual(stats.buckets(.year, in: stats.range(.year)).count, 12)
    }

    func testRhythmSplitsWorkAtHourBoundaries() {
        let stats = WorkStats(sessions: [log([(.work, 9.5, 11.25), (.pause, 11.25, 12)])], now: at(13), calendar: calendar)
        let cells = Dictionary(uniqueKeysWithValues: stats.rhythm(in: stats.range(.week)).map { ($0.id, $0.seconds) })
        let wednesdayIndex = 4 * 24
        XCTAssertEqual(cells[wednesdayIndex + 9], 1800)
        XCTAssertEqual(cells[wednesdayIndex + 10], 3600)
        XCTAssertEqual(cells[wednesdayIndex + 11], 900)
        XCTAssertEqual(stats.orderedWeekdays.first, 2)
    }

    func testPreviousPeriodIsComparedAtTheSameElapsedPoint() {
        let sessions = [log([(.work, 9, 12)], day: -7), log([(.work, 13, 17)], day: -7), log([(.work, 9, 11)])]
        let stats = WorkStats(sessions: sessions, now: at(12), calendar: calendar)
        XCTAssertEqual(stats.previousWork(.week), 3 * 3600)
        XCTAssertEqual(stats.longestStretch(in: stats.range(.week, offset: -1)), 4 * 3600)
    }

    func testFormat() {
        XCTAssertEqual(WorkStats.format(0), "0m")
        XCTAssertEqual(WorkStats.format(45 * 60), "45m")
        XCTAssertEqual(WorkStats.format(3 * 3600), "3h")
        XCTAssertEqual(WorkStats.format(3.5 * 3600 + 20), "3h 30m")
    }
}
