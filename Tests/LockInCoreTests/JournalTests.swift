import XCTest
@testable import LockInCore

final class JournalTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func makeLog(hours: Double = 4) -> WorkLog { WorkLog(todos: [Todo(title: "Ship it")], targetSeconds: hours * 3600, now: start) }
    func testEndEarlyRequiresReasonAndUsesLastActiveDayForReview() {
        var log = makeLog()
        XCTAssertTrue(log.pause(reason: "Done for today", at: start.addingTimeInterval(3600)))
        let nextMorning = start.addingTimeInterval(14 * 3600)
        XCTAssertFalse(log.endEarly(reason: "  ", at: nextMorning))
        XCTAssertNil(log.endedAt)
        XCTAssertTrue(log.endEarly(reason: " Starting a new day ", at: nextMorning))
        XCTAssertEqual(log.endedAt, nextMorning)
        XCTAssertFalse(log.finishedNaturally)
        XCTAssertEqual(log.endReason, "Starting a new day")
        XCTAssertNil(log.phase)
        XCTAssertEqual(log.seconds(.work, at: nextMorning), 3600)
        XCTAssertEqual(log.lastActiveAt, start.addingTimeInterval(3600))
        XCTAssertFalse(log.endEarly(reason: "again", at: nextMorning))
    }
    func testTwoHoursEarnTenMinutes() {
        let log = makeLog()
        XCTAssertEqual(log.breakBalance(at: start.addingTimeInterval(7200)), 600)
        XCTAssertEqual(log.breakBalance(at: start.addingTimeInterval(3600)), 300)
    }
    func testBreakCannotBeTakenBeforeEarning() {
        var log = makeLog()
        XCTAssertFalse(log.takeBreak(at: start))
        XCTAssertEqual(log.phase, .work)
    }
    func testBreakSpendsOnlyElapsedTimeAndResumesAutomatically() {
        var log = makeLog()
        XCTAssertTrue(log.takeBreak(at: start.addingTimeInterval(7200)))
        XCTAssertEqual(log.breakBalance(at: start.addingTimeInterval(7500)), 300)
        log.advance(at: start.addingTimeInterval(7800))
        XCTAssertEqual(log.phase, .work)
        XCTAssertEqual(log.seconds(.break, at: start.addingTimeInterval(7800)), 600)
        XCTAssertEqual(log.remaining(at: start.addingTimeInterval(7800)), 7200)
    }
    func testPauseRequiresReasonAndDoesNotSpendOrEarnBreak() {
        var log = makeLog()
        XCTAssertFalse(log.pause(reason: " \n ", at: start))
        XCTAssertTrue(log.pause(reason: "  Appointment  ", at: start.addingTimeInterval(7200)))
        XCTAssertEqual(log.intervals.last?.reason, "Appointment")
        XCTAssertEqual(log.breakBalance(at: start.addingTimeInterval(10800)), 600)
        XCTAssertEqual(log.remaining(at: start.addingTimeInterval(10800)), 7200)
        log.transition(to: .work, at: start.addingTimeInterval(10800))
        log.advance(at: start.addingTimeInterval(18000))
        XCTAssertEqual(log.phase, .overtime)
        XCTAssertEqual(log.seconds(.pause, at: start.addingTimeInterval(18000)), 3600)
    }
    func testOvertimeStartsExactlyAtTheWorkTarget() {
        var log = makeLog(hours: 2)
        XCTAssertTrue(log.takeBreak(at: start.addingTimeInterval(3600)))
        log.transition(to: .work, at: start.addingTimeInterval(3720))
        log.advance(at: start.addingTimeInterval(7200))
        XCTAssertEqual(log.phase, .work)
        let late = start.addingTimeInterval(9000)
        log.advance(at: late)
        XCTAssertNil(log.endedAt, "reaching the target doesn't end the session")
        XCTAssertEqual(log.phase, .overtime)
        XCTAssertEqual(log.intervals.last?.start, start.addingTimeInterval(7320))
        XCTAssertEqual(log.seconds(.work, at: late), 7200)
        XCTAssertEqual(log.seconds(.overtime, at: late), 1680)
        XCTAssertEqual(log.worked(at: late), 8880)
        XCTAssertTrue(log.complete(at: late))
        XCTAssertTrue(log.finishedNaturally)
        XCTAssertEqual(log.endedAt, late)
    }
    func testCompleteRequiresTheTarget() {
        var log = makeLog(hours: 1)
        XCTAssertFalse(log.complete(at: start.addingTimeInterval(1800)))
        XCTAssertNil(log.endedAt)
    }
    func testOvertimeEarnsBreaksAndBreaksReturnToOvertime() {
        var log = makeLog(hours: 1)
        log.advance(at: start.addingTimeInterval(7200))
        XCTAssertEqual(log.phase, .overtime)
        // 1 h work + 1 h overtime earns 10 minutes.
        XCTAssertEqual(log.breakBalance(at: start.addingTimeInterval(7200)), 600)
        XCTAssertTrue(log.takeBreak(at: start.addingTimeInterval(7200)))
        log.advance(at: start.addingTimeInterval(7800))
        XCTAssertEqual(log.phase, .overtime, "a spent break returns to overtime, not regular work")
        XCTAssertEqual(log.intervals.filter { $0.kind == .work }.count, 1, "no zero-length work interval")
        XCTAssertTrue(log.pause(reason: "Lunch", at: start.addingTimeInterval(8000)))
        XCTAssertEqual(log.focusPhase(at: start.addingTimeInterval(9000)), .overtime)
        XCTAssertEqual(log.seconds(.work, at: start.addingTimeInterval(9000)), 3600)
        XCTAssertEqual(log.seconds(.overtime, at: start.addingTimeInterval(9000)), 3800)
    }
    func testRolloverCopiesSelectedTasksWithLineage() {
        var log = makeLog()
        log.todos[0].rollForward = true; log.todos[0].completed = true
        log.todos[0].link = "https://linear.app/team/issue/ABC-1/ship"
        log.todos.append(Todo(title: "Do not roll"))
        let next = log.rolledTodos
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].sourceTodoID, log.todos[0].id)
        XCTAssertNotEqual(next[0].id, log.todos[0].id)
        XCTAssertFalse(next[0].completed)
        XCTAssertFalse(next[0].rollForward)
        XCTAssertEqual(next[0].link, log.todos[0].link)
    }
    func testEventsNeedTextAndAnOpenSession() {
        var log = makeLog()
        XCTAssertFalse(log.addEvent("  ", at: start))
        XCTAssertTrue(log.addEvent(" Deployed \n", at: start.addingTimeInterval(60)))
        XCTAssertEqual(log.events.map(\.text), ["Deployed"])
        XCTAssertEqual(log.events.first?.at, start.addingTimeInterval(60))
        _ = log.endEarly(reason: "Done", at: start.addingTimeInterval(120))
        XCTAssertFalse(log.addEvent("Too late", at: start.addingTimeInterval(180)))
    }
    func testRecoveryRoundTrip() throws {
        var state = JournalState(); var log = makeLog()
        _ = log.pause(reason: "Meeting", at: start.addingTimeInterval(60))
        state.sessions = [log]
        let restored = try JSONDecoder().decode(JournalState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.sessions[0].phase, .pause)
        XCTAssertEqual(restored.sessions[0].intervals.last?.reason, "Meeting")
    }
    func testLinksAreLabelledByService() {
        func label(_ link: String) -> String? { var todo = Todo(title: "t"); todo.link = link; return todo.linkLabel }
        XCTAssertEqual(label("https://linear.app/acme/issue/ABC-1"), "Linear")
        XCTAssertEqual(label("https://github.com/acme/app/pull/12"), "GitHub")
        XCTAssertEqual(label("https://gist.github.com/someone/abc"), "GitHub")
        XCTAssertEqual(label("https://www.notion.so/acme/Plan-123"), "Notion")
        XCTAssertEqual(label("https://acme.notion.site/Plan-123"), "Notion")
        XCTAssertEqual(label("https://www.example.com/page"), "example.com")
        XCTAssertEqual(label("https://notgithub.com/x"), "notgithub.com", "a lookalike domain is not GitHub")
        XCTAssertNil(label(""))
        XCTAssertNil(label("not a url"))
    }
    func testLinkValidation() {
        XCTAssertTrue(Todo.isValidLink(""))
        XCTAssertTrue(Todo.isValidLink("https://example.com"))
        XCTAssertTrue(Todo.isValidLink("http://intranet.local/wiki"))
        XCTAssertFalse(Todo.isValidLink("example.com"))
        XCTAssertFalse(Todo.isValidLink("javascript:alert(1)"))
        XCTAssertFalse(Todo.isValidLink("ftp://example.com/file"))
        XCTAssertTrue(Todo.isValidLink("  https://example.com  "), "whitespace is trimmed on save, so it doesn't invalidate a link")
        XCTAssertTrue(Todo(title: "t").with(title: "t", link: " https://example.com ").isValid)
    }
    /// Journals saved before links were generalized store the link under "linearURL"; they must load, and keep that key.
    func testTaskLinkKeepsItsSavedKey() throws {
        let id = UUID()
        let json = #"{"id":"\#(id)","title":"Old task","linearURL":"https://linear.app/acme/issue/ABC-1","completed":false,"rollForward":true}"#
        let todo = try JSONDecoder().decode(Todo.self, from: Data(json.utf8))
        XCTAssertEqual(todo.link, "https://linear.app/acme/issue/ABC-1")
        XCTAssertEqual(todo.linkService, .linear)
        XCTAssertTrue(todo.rollForward)
        let encoded = String(decoding: try JSONEncoder().encode(todo), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"linearURL\""))
        let file = SessionFile(WorkLog(todos: [todo], targetSeconds: 60, now: start), checkpoint: nil)
        XCTAssertEqual(file.tasks.first?.link, "https://linear.app/acme/issue/ABC-1", "session files call it link")
    }
}
