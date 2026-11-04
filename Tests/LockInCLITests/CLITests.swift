import XCTest
import LockInCore
@testable import LockInCLI

final class ParseTests: XCTestCase {
    func testCommands() throws {
        XCTAssertEqual(try parse([]), .status(json: false))
        XCTAssertEqual(try parse(["open"]), .open)
        XCTAssertEqual(try parse(["status", "--json"]), .status(json: true))
        XCTAssertEqual(try parse(["start"]), .start(hours: nil))
        XCTAssertEqual(try parse(["start", "--hours", "6.5"]), .start(hours: 6.5))
        XCTAssertEqual(try parse(["pause", "lunch with Sam"]), .pause(reason: "lunch with Sam"))
        XCTAssertEqual(try parse(["end", "Starting a new day"]), .end(reason: "Starting a new day"))
        XCTAssertEqual(try parse(["break"]), .takeBreak)
        XCTAssertEqual(try parse(["history", "-n", "3"]), .history(count: 3))
        XCTAssertEqual(try parse(["history"]), .history(count: 7))
        XCTAssertEqual(try parse(["upgrade"]), .upgrade)
        XCTAssertEqual(try parse(["task", "add", "Ship it"]), .addTask(TaskText(title: "Ship it")))
        XCTAssertEqual(try parse(["task", "2", "https://github.com/a/b/pull/3"]), .updateTask(number: 2, TaskText(link: "https://github.com/a/b/pull/3")))
        XCTAssertEqual(try parse(["task", "done", "2"]), .setTaskCompleted(number: 2, completed: true))
        XCTAssertEqual(try parse(["task", "undo", "2"]), .setTaskCompleted(number: 2, completed: false))
        XCTAssertEqual(try parse(["task", "rm", "1"]), .deleteTask(number: 1))
    }
    func testUsageErrors() {
        for args in [["pause"], ["pause", "  "], ["end"], ["start", "--hours", "25"], ["start", "--hours"], ["status", "extra"],
                     ["task"], ["task", "add"], ["task", "done", "0"], ["task", "done", "x"], ["task", "0", "x"], ["task", "2"],
                     ["history", "-n", "-1"], ["upgrade", "now"], ["bogus"],
                     ["task", "add", "Ship it", "--link", "https://linear.app/x/issue/A-1"]] {
            XCTAssertThrowsError(try parse(args), "\(args)")
        }
    }
    func testTextWithSpacesMustBeQuoted() {
        for (args, fix) in [(["pause", "lunch", "with", "Sam"], #"lockin pause "lunch with Sam""#),
                            (["end", "Starting", "a", "new", "day"], #"lockin end "Starting a new day""#),
                            (["task", "add", "Ship", "it"], #"lockin task add "Ship it""#),
                            (["task", "3", "New", "name"], #"lockin task 3 "New name""#)] {
            XCTAssertThrowsError(try parse(args)) { XCTAssertTrue(($0 as? UsageError)?.message.contains(fix) == true, "\($0)") }
        }
    }
    func testTaskText() throws {
        XCTAssertEqual(try parseTaskText("Write docs"), TaskText(title: "Write docs"))
        XCTAssertEqual(try parseTaskText("https://linear.app/s/issue/FUNC-1/fix-it"), TaskText(link: "https://linear.app/s/issue/FUNC-1/fix-it"))
        XCTAssertEqual(try parseTaskText("Fix it - https://linear.app/s/issue/FUNC-1"), TaskText(title: "Fix it", link: "https://linear.app/s/issue/FUNC-1"))
        XCTAssertEqual(try parseTaskText("Ops - rotate keys - https://x.com/a"), TaskText(title: "Ops - rotate keys", link: "https://x.com/a"),
                       "titles can contain the separator")
        XCTAssertEqual(try parseTaskText("Before - after"), TaskText(title: "Before - after"))
        XCTAssertThrowsError(try parseTaskText("Fix it - https://"), "a mistyped link isn't folded into the title")
        XCTAssertEqual(TaskText(link: "https://linear.app/s/issue/FUNC-1/fix-it").newTitle, "FUNC-1 fix it")
    }
    func testVersionOrdering() {
        XCTAssertEqual(Upgrade.compare("0.10.0", "0.9.1"), .orderedDescending)
        XCTAssertEqual(Upgrade.compare("0.3.0", "0.4.0"), .orderedAscending)
        XCTAssertEqual(Upgrade.compare("1.0", "1.0.0"), .orderedSame)
    }
}

final class ReportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func todo(_ title: String, link: String = "", done: Bool = false) -> Todo {
        var todo = Todo(title: title); todo.link = link; todo.completed = done; return todo
    }
    private func snapshot(_ journal: JournalState, at offset: TimeInterval, locked: Bool = false) -> Snapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Snapshot(journal: journal, locked: locked, asOf: start.addingTimeInterval(offset), calendar: calendar)
    }

    func testWorkingStatusAndTaskNumbers() throws {
        var journal = JournalState()
        journal.sessions = [WorkLog(todos: [todo("Write docs", done: true), todo("Fix bug", link: "https://github.com/a/b/pull/1")],
                                    targetSeconds: 8 * 3600, now: start)]
        let status = snapshot(journal, at: 2 * 3600, locked: true)
        XCTAssertTrue(status.statusText.contains("Working · 06:00:00 left of 8h"), status.statusText)
        XCTAssertTrue(status.statusText.contains("Worked 2h of 8h · break balance 10m · Hardcore Mode"), status.statusText)
        XCTAssertTrue(status.statusText.contains("  1. [x] Write docs"))
        XCTAssertTrue(status.statusText.contains("  2. [ ] Fix bug — https://github.com/a/b/pull/1"))
        XCTAssertEqual(try status.task(number: 2).title, "Fix bug")
        XCTAssertThrowsError(try status.task(number: 3))
    }

    func testPausedAndNotRunning() {
        var journal = JournalState()
        var log = WorkLog(todos: [todo("A")], targetSeconds: 3600, now: start)
        _ = log.pause(reason: "lunch", at: start.addingTimeInterval(600))
        journal.sessions = [log]
        var status = snapshot(journal, at: 900)
        status.appRunning = false
        XCTAssertTrue(status.statusText.contains("Paused since"))
        XCTAssertTrue(status.statusText.contains("“lunch”"))
        XCTAssertTrue(status.statusText.contains("Lock In isn't running"))
        XCTAssertEqual(status.status.phase, "pause")
        XCTAssertEqual(status.status.pauseReason, "lunch")
        XCTAssertEqual(status.status.workedSeconds, 600)
    }

    func testOvertimeUnlocksHardcore() {
        var journal = JournalState()
        var log = WorkLog(todos: [todo("A")], targetSeconds: 3600, now: start)
        log.advance(at: start.addingTimeInterval(4000))
        journal.sessions = [log]
        let status = snapshot(journal, at: 4000, locked: true)
        XCTAssertTrue(status.statusText.contains("Overtime · +00:06:40 past the 1h target"), status.statusText)
        XCTAssertFalse(status.statusText.contains("Hardcore"))
        XCTAssertFalse(status.status.locked)
    }

    func testNoSessionShowsPlanWithoutBlankRows() throws {
        var journal = JournalState()
        journal.hours = 6
        journal.draft = [todo("Plan this"), Todo()]
        let status = snapshot(journal, at: 0)
        XCTAssertTrue(status.statusText.hasPrefix("No session running. Plan: 6h · 1 task."), status.statusText)
        XCTAssertTrue(status.tasksText.contains("  1. Plan this"))
        XCTAssertNil(status.status.phase)
        XCTAssertTrue(status.statusJSON.contains("\"title\" : \"Plan this\""))
        journal.pendingReviewID = UUID()
        XCTAssertTrue(snapshot(journal, at: 0).statusText.contains("waiting for review"))
    }

    func testHistoryNewestFirst() {
        var journal = JournalState()
        var first = WorkLog(todos: [todo("A", done: true)], targetSeconds: 3600, now: start)
        first.advance(at: start.addingTimeInterval(3600 + 600))
        _ = first.complete(at: start.addingTimeInterval(3600 + 600))
        var second = WorkLog(todos: [todo("B")], targetSeconds: 7200, now: start.addingTimeInterval(86_400))
        _ = second.endEarly(reason: "Starting a new day", at: start.addingTimeInterval(86_400 + 1800))
        journal.sessions = [first, second]
        let lines = snapshot(journal, at: 2 * 86_400).historyText(count: 7).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("30m / 2h"), String(lines[0]))
        XCTAssertTrue(lines[0].contains("ended early: Starting a new day"))
        XCTAssertTrue(lines[1].contains("1/1 tasks"))
        XCTAssertTrue(lines[1].contains("finished (+10m overtime)"), String(lines[1]))
        XCTAssertEqual(snapshot(journal, at: 0).historyText(count: 1).split(separator: "\n").count, 1)
    }
}

final class BackfillRangeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar
    }()
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + ":00Z")! }
    private func resolve(_ range: String, now: String) throws -> [Date] {
        let r = try BackfillRange.resolve(range, now: date(now), calendar: calendar); return [r.start, r.end]
    }

    func testTimesMeanTheirMostRecentPastOccurrence() throws {
        XCTAssertEqual(try resolve("9:00-10:30", now: "2026-11-04T15:00"), [date("2026-11-04T09:00"), date("2026-11-04T10:30")])
        XCTAssertEqual(try resolve("16:00-17:30", now: "2026-11-04T15:00"), [date("2026-11-03T16:00"), date("2026-11-03T17:30")], "later today hasn't happened yet")
    }
    func testRangesRunPastMidnight() throws {
        XCTAssertEqual(try resolve("22:30-01:15", now: "2026-11-04T15:00"), [date("2026-11-03T22:30"), date("2026-11-04T01:15")])
        XCTAssertEqual(try resolve("23:00-00:20", now: "2026-11-04T00:40"), [date("2026-11-03T23:00"), date("2026-11-04T00:20")], "last night, just after midnight")
        XCTAssertEqual(try resolve("23:00-now", now: "2026-11-04T00:40"), [date("2026-11-03T23:00"), date("2026-11-04T00:40")])
        XCTAssertEqual(try resolve("6:20-now", now: "2026-11-04T07:40"), [date("2026-11-04T06:20"), date("2026-11-04T07:40")])
    }
    func testDatedRanges() throws {
        XCTAssertEqual(try resolve("2026-11-01T22:30-2026-11-02T01:15", now: "2026-11-04T15:00"), [date("2026-11-01T22:30"), date("2026-11-02T01:15")])
        XCTAssertEqual(try resolve("2026-11-01T22:30-01:15", now: "2026-11-04T15:00"), [date("2026-11-01T22:30"), date("2026-11-02T01:15")])
        XCTAssertEqual(try resolve("21:00-2026-11-02T01:15", now: "2026-11-04T15:00"), [date("2026-11-01T21:00"), date("2026-11-02T01:15")])
    }
    func testBadRanges() {
        for range in ["9-10", "9:00", "25:00-26:00", "9:60-10:00", "now-9:00", "2026-02-31T09:00-10:00", "2026-11-05T09:00-10:00", "9:00-9:00"] {
            XCTAssertThrowsError(try resolve(range, now: "2026-11-04T15:00"), range)
        }
    }
    func testParse() throws {
        XCTAssertEqual(try parse(["backfill", "9:00-10:30"]), .backfill(range: "9:00-10:30"))
        XCTAssertEqual(try parse(["backfill", "--undo"]), .undoBackfill)
        XCTAssertThrowsError(try parse(["backfill"]))
        XCTAssertThrowsError(try parse(["backfill", "--undo", "9:00-10:00"]))
    }
}
