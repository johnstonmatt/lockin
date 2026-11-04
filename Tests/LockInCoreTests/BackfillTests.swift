import XCTest
@testable import LockInCore

final class BackfillTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    /// A session started at minute 0 that worked `worked` minutes, then paused (open) with `reason`.
    private func pausedSession(worked: Double, target: Double = 480, reason: String = "Mac went to sleep") -> JournalState {
        var log = WorkLog(todos: [Todo(title: "A")], targetSeconds: target * 60, now: at(0))
        _ = log.pause(reason: reason, at: at(worked))
        var journal = JournalState(); journal.sessions = [log]
        return journal
    }

    func testPauseBecomesWorkAndTheRestStaysPaused() throws {
        var journal = pausedSession(worked: 60)
        let pauseID = journal.sessions[0].intervals[1].id
        let result = try journal.backfill(from: at(60), to: at(120), now: at(130))
        XCTAssertEqual(result.addedSeconds, 3600)
        XCTAssertFalse(result.createdSession)
        let kinds = journal.sessions[0].intervals.map(\.kind), filled = journal.sessions[0].intervals.map { $0.backfilled == true }
        XCTAssertEqual(kinds, [.work, .work, .pause])
        XCTAssertEqual(filled, [false, true, false])
        let rest = try XCTUnwrap(journal.sessions[0].intervals.last)
        XCTAssertEqual(rest.id, pauseID, "the open pause keeps its identity")
        XCTAssertNil(rest.end)
        XCTAssertEqual(rest.reason, "Mac went to sleep")
        XCTAssertEqual(journal.sessions[0].worked(at: at(130)), 2 * 3600)
    }

    func testPauseSplitOnBothSides() throws {
        var journal = pausedSession(worked: 60)
        _ = try journal.backfill(from: at(70), to: at(80), now: at(130))
        let log = journal.sessions[0]
        XCTAssertEqual(log.intervals.map(\.kind), [.work, .pause, .work, .pause])
        XCTAssertEqual(Set(log.intervals.map(\.id)).count, 4, "split intervals get their own IDs")
        XCTAssertEqual(log.intervals[1].end, at(70))
        XCTAssertEqual(log.intervals[1].reason, "Mac went to sleep")
    }

    func testRunningIntoTheStartMovesItEarlier() throws {
        var journal = pausedSession(worked: 60)
        // Typed to the minute, overlapping a few minutes of timed work: that part is already counted.
        let result = try journal.backfill(from: at(-90), to: at(5), now: at(130))
        XCTAssertTrue(result.movedStart)
        XCTAssertEqual(result.addedSeconds, 90 * 60)
        XCTAssertEqual(result.alreadyRecordedSeconds, 5 * 60)
        XCTAssertEqual(journal.sessions[0].startedAt, at(-90))
        XCTAssertEqual(journal.sessions[0].intervals.first?.backfilled, true)
        // Ending just short of the start still counts as running into it.
        var other = pausedSession(worked: 60)
        XCTAssertTrue(try other.backfill(from: at(-30), to: at(-0.5), now: at(130)).movedStart)
    }

    func testRangeOutsideEverySessionIsANewReviewedSessionInOrder() throws {
        var journal = pausedSession(worked: 60)
        // Across midnight, a day earlier: still one session.
        let result = try journal.backfill(from: at(-24 * 60 - 90), to: at(-24 * 60 + 75), now: at(130))
        XCTAssertTrue(result.createdSession)
        XCTAssertEqual(journal.sessions.count, 2)
        let added = journal.sessions[0]
        XCTAssertEqual(added.startedAt, at(-24 * 60 - 90), "inserted before the later session")
        XCTAssertTrue(added.reviewed)
        XCTAssertTrue(added.finishedNaturally)
        XCTAssertEqual(added.targetSeconds, 165 * 60)
        XCTAssertEqual(added.worked(at: at(130)), 165 * 60)
        XCTAssertEqual(added.seconds(.overtime, at: at(130)), 0)
        XCTAssertNotNil(journal.sessions.last?.phase, "the open session is still the last one")
    }

    func testRefusals() throws {
        var journal = pausedSession(worked: 60)
        XCTAssertThrowsError(try journal.backfill(from: at(10), to: at(50), now: at(130))) { XCTAssertEqual($0 as? BackfillError, .nothingToAdd) }
        XCTAssertThrowsError(try journal.backfill(from: at(120), to: at(200), now: at(130))) { XCTAssertEqual($0 as? BackfillError, .inFuture) }
        XCTAssertThrowsError(try journal.backfill(from: at(90), to: at(80), now: at(130))) { XCTAssertEqual($0 as? BackfillError, .empty) }

        var finished = WorkLog(todos: [], targetSeconds: 3600, now: at(-300))
        finished.finish(at: at(-200), natural: false)
        journal.sessions.insert(finished, at: 0)
        XCTAssertThrowsError(try journal.backfill(from: at(-250), to: at(-150), now: at(130))) {
            XCTAssertEqual($0 as? BackfillError, .afterEnd(sessionEnd: at(-200)))
        }
        XCTAssertThrowsError(try journal.backfill(from: at(-250), to: at(30), now: at(130))) {
            XCTAssertEqual($0 as? BackfillError, .spansSessions(firstEnds: at(-200), nextStarts: at(0)))
        }
        XCTAssertNil(journal.lastBackfill, "refusals change nothing")
    }

    func testEarlierWorkMovesTheTargetAndLaterWorkBecomesOvertime() throws {
        var log = WorkLog(todos: [], targetSeconds: 3600, now: at(0))
        _ = log.pause(reason: "Forgot", at: at(30))
        log.transition(to: .work, at: at(60))
        var journal = JournalState(); journal.sessions = [log]
        _ = try journal.backfill(from: at(30), to: at(60), now: at(80))
        let updated = journal.sessions[0]
        XCTAssertEqual(updated.intervals.map(\.kind), [.work, .work, .overtime], "the target was reached at minute 60")
        XCTAssertEqual(updated.phase, .overtime)
        XCTAssertEqual(updated.seconds(.overtime, at: at(80)), 20 * 60)
    }

    func testUndoKeepsWhatHappenedSince() throws {
        var journal = pausedSession(worked: 60)
        let before = journal.sessions[0].intervals.map(\.kind)
        _ = try journal.backfill(from: at(-30), to: at(100), now: at(110))
        // After the backfill, work resumes.
        journal.sessions[0].transition(to: .work, at: at(120))
        XCTAssertTrue(journal.undoBackfill(now: at(130)))
        let log = journal.sessions[0]
        XCTAssertEqual(log.startedAt, at(0))
        XCTAssertEqual(log.intervals.map(\.kind), before + [.work])
        XCTAssertEqual(log.intervals[1].end, at(120), "the pause ends where the resumed work began")
        XCTAssertFalse(log.intervals.contains { $0.backfilled == true })
        XCTAssertFalse(journal.undoBackfill(now: at(130)), "only once")

        var created = pausedSession(worked: 60)
        _ = try created.backfill(from: at(-300), to: at(-200), now: at(130))
        XCTAssertTrue(created.undoBackfill(now: at(130)))
        XCTAssertEqual(created.sessions.count, 1)
    }

    func testIntervalsWithoutTheFlagStillDecode() throws {
        let json = #"{"id":"\#(UUID())","kind":"work","start":0,"end":60}"#
        XCTAssertNil(try JSONDecoder().decode(WorkInterval.self, from: Data(json.utf8)).backfilled)
    }
}
