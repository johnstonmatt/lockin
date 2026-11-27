import XCTest
import LockInCore
@testable import LockIn

/// `Store.perform`, which carries out `lockin` CLI commands.
final class RemoteCommandTests: StoreTestCase {

    func testWireFormatRoundTrips() {
        let command = RemoteCommand.setTaskCompleted(id: UUID(), completed: true)
        XCTAssertEqual(RemoteChannel.decode(RemoteCommand.self, from: RemoteChannel.encode(command)), command)
        XCTAssertNil(RemoteChannel.decode(RemoteCommand.self, from: ["payload": "nonsense"]))
    }

    @MainActor func testStartWithoutTasksThenAddWork() async throws {
        let store = makeStore()
        let reply = await store.perform(.start(hours: 2))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertTrue(store.active)
        XCTAssertEqual(store.workLog?.targetSeconds, 7200)
        XCTAssertEqual(store.workLog?.todos.count, 0)
        let commandReply = await store.perform(.addTask(title: "Docs", link: ""))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Docs"])
        XCTAssertEqual(makeStore().workLog?.todos.map(\.title), ["Docs"])
    }

    @MainActor func testPlanStartPauseBreakResume() async throws {
        let store = makeStore()
        var commandReply = await store.perform(.addTask(title: "Docs", link: "not a link"))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.addTask(title: "Docs", link: ""))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.journal.draft.map(\.title), ["Docs"], "the planner's blank row is dropped")
        XCTAssertEqual(makeStore().journal.draft.map(\.title), ["Docs"], "the plan is saved")
        let planned = try XCTUnwrap(store.journal.draft.first?.id)
        commandReply = await store.perform(.updateTask(id: planned, title: "Write docs", link: "https://notion.so/x/Docs"))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(makeStore().journal.draft.first?.title, "Write docs", "plan edits are saved")

        commandReply = await store.perform(.start(hours: 2))
        XCTAssertTrue(commandReply.ok)
        XCTAssertTrue(store.active)
        commandReply = await store.perform(.start(hours: nil))
        XCTAssertFalse(commandReply.ok, "already running")
        commandReply = await store.perform(.takeBreak)
        XCTAssertFalse(commandReply.ok, "no break earned yet")
        commandReply = await store.perform(.pause(reason: " "))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.pause(reason: "Standup"))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.workLog?.intervals.last?.reason, "Standup")
        commandReply = await store.perform(.pause(reason: "Again"))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.resume)
        XCTAssertTrue(commandReply.ok)
        commandReply = await store.perform(.resume)
        XCTAssertFalse(commandReply.ok, "already working")

        clock.advance(by: 3600)
        let reply = await store.perform(.takeBreak)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(store.workLog?.phase, .break)
    }

    @MainActor func testTasksDuringASession() async throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "First")]
        store.start()
        var commandReply = await store.perform(.addTask(title: "Second", link: "https://example.com/task"))
        XCTAssertTrue(commandReply.ok)
        let ids = try XCTUnwrap(store.workLog?.todos.map(\.id))
        commandReply = await store.perform(.setTaskCompleted(id: ids[1], completed: true))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.workLog?.todos[1].completed, true)
        commandReply = await store.perform(.updateTask(id: ids[1], title: "Second, renamed", link: nil))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.workLog?.todos[1].link, "https://example.com/task", "a title alone keeps the link")
        commandReply = await store.perform(.updateTask(id: ids[1], title: nil, link: "https://github.com/a/b/pull/3"))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.workLog?.todos[1].title, "Second, renamed", "a link alone keeps the title")
        XCTAssertEqual(store.workLog?.todos[1].link, "https://github.com/a/b/pull/3")
        commandReply = await store.perform(.updateTask(id: ids[1], title: nil, link: "nope"))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.deleteTask(id: ids[0]))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Second, renamed"])
        commandReply = await store.perform(.deleteTask(id: UUID()))
        XCTAssertFalse(commandReply.ok)
    }

    @MainActor func testFinishAndEnd() async throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Task")]
        store.journal.hours = 1
        store.start()
        let early = await store.perform(.finish)
        XCTAssertFalse(early.ok)
        XCTAssertTrue(early.message.contains("lockin end"), early.message)
        var commandReply = await store.perform(.end(reason: ""))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.end(reason: "Starting a new day"))
        XCTAssertTrue(commandReply.ok)
        XCTAssertFalse(store.active)
        commandReply = await store.perform(.addTask(title: "Lost", link: ""))
        XCTAssertFalse(commandReply.ok, "the review would overwrite the plan")
        commandReply = await store.perform(.start(hours: nil))
        XCTAssertFalse(commandReply.ok, "review first")
    }

    @MainActor func testHardcoreRefusesEnd() async {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Task")]
        store.lockSession = true
        store.start()
        let commandReply = await store.perform(.end(reason: "Bored"))
        XCTAssertFalse(commandReply.ok)
        XCTAssertTrue(store.active)
    }

    @MainActor func testBackfillAndUndo() async {
        let store = makeStore()
        let end = clock.now.addingTimeInterval(-3600), start = end.addingTimeInterval(-1800)
        var commandReply = await store.perform(.backfill(start: end, end: start))
        XCTAssertFalse(commandReply.ok, "the range ends before it starts")
        XCTAssertTrue(store.journal.sessions.isEmpty)
        commandReply = await store.perform(.backfill(start: start, end: end))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(makeStore().journal.sessions.map(\.startedAt), [start], "the backfill is saved as a new session")
        commandReply = await store.perform(.backfill(start: start, end: end))
        XCTAssertFalse(commandReply.ok, "already recorded")
        XCTAssertEqual(store.journal.sessions.count, 1, "a refused backfill leaves the journal as it was")
        commandReply = await store.perform(.undoBackfill)
        XCTAssertTrue(commandReply.ok)
        XCTAssertTrue(makeStore().journal.sessions.isEmpty, "the undo is saved")
        commandReply = await store.perform(.undoBackfill)
        XCTAssertFalse(commandReply.ok, "nothing left to undo")
    }

    @MainActor func testEventsAreRecordedOnTheRunningSession() async throws {
        let store = makeStore()
        var commandReply = await store.perform(.addEvent(text: "Too early"))
        XCTAssertFalse(commandReply.ok, "no session yet")
        store.journal.draft = [Todo(title: "Task")]
        store.start()
        commandReply = await store.perform(.addEvent(text: "  "))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.pause(reason: "Lunch"))
        XCTAssertTrue(commandReply.ok)
        let reply = await store.perform(.addEvent(text: " Deployed to staging "))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(reply.message, "Recorded “Deployed to staging”.")
        XCTAssertEqual(makeStore().workLog?.events.map(\.text), ["Deployed to staging"], "events are saved, paused or not")
    }

    @MainActor func testDeletingFromThePlan() async throws {
        let store = makeStore()
        var commandReply = await store.perform(.addTask(title: "Only", link: ""))
        XCTAssertTrue(commandReply.ok)
        let id = try XCTUnwrap(store.journal.draft.first?.id)
        commandReply = await store.perform(.updateTask(id: id, title: " ", link: nil))
        XCTAssertFalse(commandReply.ok, "a task needs a title")
        commandReply = await store.perform(.deleteTask(id: UUID()))
        XCTAssertFalse(commandReply.ok)
        commandReply = await store.perform(.deleteTask(id: id))
        XCTAssertTrue(commandReply.ok)
        XCTAssertEqual(makeStore().journal.draft.count, 1, "the planner keeps a blank row")
        XCTAssertFalse(makeStore().journal.draft[0].hasTitle)
    }

    @MainActor func testUnsavedChangesAreRolledBack() async throws {
        let store = makeStore()
        // A file where the sessions directory should be makes every write fail.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: Storage.sessionsDirectory(in: directory))
        let reply = await store.perform(.addTask(title: "Lost", link: ""))
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.message.contains("Could not save"), reply.message)
        XCTAssertFalse(store.journal.draft.contains { $0.title == "Lost" }, "the journal in memory matches the one on disk")
    }

    @MainActor func testPing() async {
        let reply = await makeStore().perform(.ping)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.message, "Lock In is running.")
    }

    @MainActor func testStartRefusesAnInvalidTarget() async {
        let store = makeStore()
        let hours = store.journal.hours
        for invalid in [0, -1, 24.5, .infinity] {
            let reply = await store.perform(.start(hours: invalid))
            XCTAssertFalse(reply.ok, "\(invalid)")
            XCTAssertEqual(reply.message, "Use a work target between 0 and 24 hours.")
        }
        XCTAssertFalse(store.active)
        XCTAssertEqual(store.journal.hours, hours, "a refused target isn't saved")
    }

    @MainActor func testBreakWhilePausedIsRefused() async {
        let store = makeStore()
        store.start()
        clock.advance(by: 3600)
        store.pause(reason: "Lunch")
        let reply = await store.perform(.takeBreak)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.message, "Resume before taking a break.")
        XCTAssertEqual(store.workLog?.phase, .pause)
    }

    @MainActor func testFinishOnceTheTargetIsReached() async throws {
        let store = makeStore()
        store.journal.hours = 1
        store.start()
        let id = try XCTUnwrap(store.workLog?.id)
        clock.advance(by: 3600)
        let reply = await store.perform(.finish)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(reply.message, "Session finished. Review it in Lock In.")
        XCTAssertNil(store.workLog)
        XCTAssertEqual(store.journal.pendingReviewID, id)
        XCTAssertEqual(store.journal.sessions.last?.finishedNaturally, true)
        XCTAssertEqual(store.journal.sessions.last?.endedAt, clock.now)
    }

    @MainActor func testBackfillIntoTheOpenSession() async throws {
        let store = makeStore()
        store.journal.hours = 1
        store.start()
        let started = clock.now
        clock.advance(by: 40 * 60)
        // Forgot to start half an hour earlier; the range overlaps five minutes already timed.
        let moved = await store.perform(.backfill(start: started.addingTimeInterval(-30 * 60), end: started.addingTimeInterval(5 * 60)))
        XCTAssertTrue(moved.ok, moved.message)
        XCTAssertTrue(moved.message.hasPrefix("Backfilled 30m:"), moved.message)
        XCTAssertTrue(moved.message.contains("The session now starts"), moved.message)
        XCTAssertTrue(moved.message.contains("5m of it was already recorded."), moved.message)
        XCTAssertEqual(store.workLog?.startedAt, started.addingTimeInterval(-30 * 60))
        XCTAssertEqual(store.workLog?.phase, .overtime, "70 minutes worked passes the 1h target")
        XCTAssertEqual(makeStore().workLog?.startedAt, started.addingTimeInterval(-30 * 60), "the backfill is saved")

        store.pause(reason: "Forgot to resume")
        clock.advance(by: 20 * 60)
        let inside = await store.perform(.backfill(start: started.addingTimeInterval(40 * 60), end: started.addingTimeInterval(50 * 60)))
        XCTAssertTrue(inside.ok, inside.message)
        XCTAssertTrue(inside.message.contains(", in the session that started"), inside.message)
        XCTAssertFalse(inside.message.contains("already recorded"), inside.message)
    }

    @MainActor func testBackfillExplainsRangesThatDontFitASession() async throws {
        let store = makeStore()
        let now = clock.now
        var earlier = WorkLog(todos: [], targetSeconds: 3600, now: now.addingTimeInterval(-5 * 3600))
        earlier.intervals[0].end = now.addingTimeInterval(-4 * 3600)
        earlier.endedAt = now.addingTimeInterval(-4 * 3600)
        earlier.reviewed = true
        XCTAssertTrue(store.commitJournal { $0.sessions = [earlier] })
        let afterEnd = await store.perform(.backfill(start: now.addingTimeInterval(-4.5 * 3600), end: now.addingTimeInterval(-3.5 * 3600)))
        XCTAssertFalse(afterEnd.ok)
        XCTAssertEqual(afterEnd.message, Store.explain(.afterEnd(sessionEnd: now.addingTimeInterval(-4 * 3600))))

        store.start()
        clock.advance(by: 600)
        let spans = await store.perform(.backfill(start: now.addingTimeInterval(-4.5 * 3600), end: now.addingTimeInterval(300)))
        XCTAssertFalse(spans.ok)
        XCTAssertEqual(spans.message, Store.explain(.spansSessions(firstEnds: now.addingTimeInterval(-4 * 3600), nextStarts: now)))
        XCTAssertNil(store.journal.lastBackfill, "refusals change nothing")
    }

    @MainActor func testPlanEditsWaitForThePendingReview() async throws {
        let store = makeStore()
        let added = await store.perform(.addTask(title: "Planned", link: ""))
        XCTAssertTrue(added.ok, added.message)
        let id = try XCTUnwrap(store.journal.draft.first?.id)
        store.journal.pendingReviewID = UUID()
        let plan = store.journal.draft
        for command in [RemoteCommand.updateTask(id: id, title: "Renamed", link: nil), .deleteTask(id: id)] {
            let reply = await store.perform(command)
            XCTAssertFalse(reply.ok, "\(command)")
            XCTAssertEqual(reply.message, Store.reviewFirstMessage)
        }
        XCTAssertEqual(store.journal.draft, plan)
    }

    @MainActor func testTicksNeedASession() async {
        let reply = await makeStore().perform(.setTaskCompleted(id: UUID(), completed: true))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.message, "Tasks can be checked off during a session.")
    }
}

/// The notification round trip the CLI uses, against a listening store with its own temporary journal.
final class RemoteChannelTests: StoreTestCase {
    @MainActor func testRequestGetsAReply() async throws {
        // A channel of its own: on the app's channel, a running Lock In would get this task too.
        let channel = RemoteChannel(name: "app.lockin.mac.tests.\(UUID().uuidString)")
        let store = makeStore(channel: channel)
        let center = DistributedNotificationCenter.default()
        let id = UUID().uuidString
        let replied = expectation(description: "reply")
        var reply: RemoteReply?
        let observer = center.addObserver(forName: channel.reply, object: id, queue: .main) { note in
            reply = RemoteChannel.decode(RemoteReply.self, from: note.userInfo); replied.fulfill()
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(channel.request, object: id, userInfo: RemoteChannel.encode(RemoteCommand.addTask(title: "Via CLI", link: "")), deliverImmediately: true)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(reply?.ok, true, reply?.message ?? "no reply")
        XCTAssertEqual(store.journal.draft.map(\.title), ["Via CLI"])
    }
}
