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
        XCTAssertTrue(SessionYAML.encode(log, at: nextMorning).contains("end_reason: \"Starting a new day\""))
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
        XCTAssertTrue(log.finishedNaturally)
        XCTAssertEqual(log.seconds(.pause, at: start.addingTimeInterval(18000)), 3600)
    }
    func testNaturalFinishUsesActualWorkTarget() {
        var log = makeLog(hours: 2)
        XCTAssertTrue(log.takeBreak(at: start.addingTimeInterval(3600)))
        log.transition(to: .work, at: start.addingTimeInterval(3720))
        log.advance(at: start.addingTimeInterval(7200))
        XCTAssertNil(log.endedAt)
        log.advance(at: start.addingTimeInterval(9000))
        XCTAssertEqual(log.endedAt, start.addingTimeInterval(7320))
        XCTAssertEqual(log.seconds(.work, at: start.addingTimeInterval(9000)), 7200)
    }
    func testRolloverCopiesSelectedTasksWithLineage() {
        var log = makeLog()
        log.todos[0].rollForward = true; log.todos[0].completed = true
        log.todos[0].linearURL = "https://linear.app/team/issue/ABC-1/ship"
        log.todos.append(Todo(title: "Do not roll"))
        let next = log.rolledTodos
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].sourceTodoID, log.todos[0].id)
        XCTAssertNotEqual(next[0].id, log.todos[0].id)
        XCTAssertFalse(next[0].completed)
        XCTAssertFalse(next[0].rollForward)
        XCTAssertEqual(next[0].linearURL, log.todos[0].linearURL)
    }
    func testYAMLEscapesUserTextAndTracksPause() {
        var log = makeLog()
        log.todos[0].title = "Quote: \"ship\"\nnext line"
        _ = log.pause(reason: "Call: urgent\nsecond line", at: start.addingTimeInterval(60))
        let yaml = SessionYAML.encode(log, at: start.addingTimeInterval(120))
        XCTAssertTrue(yaml.contains("kind: pause"))
        XCTAssertTrue(yaml.contains("duration_seconds: 60.0"))
        XCTAssertTrue(yaml.contains("\\nnext line"))
        XCTAssertTrue(yaml.contains("reason: \"Call: urgent\\nsecond line\""))
    }
    func testRecoveryRoundTrip() throws {
        var state = JournalState(); var log = makeLog()
        _ = log.pause(reason: "Meeting", at: start.addingTimeInterval(60))
        state.sessions = [log]
        let restored = try JSONDecoder().decode(JournalState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.sessions[0].phase, .pause)
        XCTAssertEqual(restored.sessions[0].intervals.last?.reason, "Meeting")
    }
}
