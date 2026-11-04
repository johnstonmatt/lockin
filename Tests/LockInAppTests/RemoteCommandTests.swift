import XCTest
import LockInCore
@testable import LockIn

/// `Store.perform`, which carries out `lockin` CLI commands.
final class RemoteCommandTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    @MainActor private func makeStore() -> Store {
        Store(directory: directory, runTimer: false, enforceBlocking: false, channel: nil)
    }

    func testWireFormatRoundTrips() {
        let command = RemoteCommand.setTaskCompleted(id: UUID(), completed: true)
        XCTAssertEqual(RemoteChannel.decode(RemoteCommand.self, from: RemoteChannel.encode(command)), command)
        XCTAssertNil(RemoteChannel.decode(RemoteCommand.self, from: ["payload": "nonsense"]))
    }

    @MainActor func testPlanStartPauseBreakResume() throws {
        let store = makeStore()
        XCTAssertFalse(store.perform(.start(hours: 2)).ok, "no tasks yet")
        XCTAssertEqual(store.journal.hours, 2, "the target is kept for the plan")
        XCTAssertFalse(store.perform(.addTask(title: "Docs", link: "not a link")).ok)
        XCTAssertTrue(store.perform(.addTask(title: "Docs", link: "")).ok)
        XCTAssertEqual(store.journal.draft.map(\.title), ["Docs"], "the planner's blank row is dropped")
        XCTAssertEqual(makeStore().journal.draft.map(\.title), ["Docs"], "the plan is saved")
        let planned = try XCTUnwrap(store.journal.draft.first?.id)
        XCTAssertTrue(store.perform(.updateTask(id: planned, title: "Write docs", link: "https://notion.so/x/Docs")).ok)
        XCTAssertEqual(makeStore().journal.draft.first?.title, "Write docs", "plan edits are saved")

        XCTAssertTrue(store.perform(.start(hours: nil)).ok)
        XCTAssertTrue(store.active)
        XCTAssertFalse(store.perform(.start(hours: nil)).ok, "already running")
        XCTAssertFalse(store.perform(.takeBreak).ok, "no break earned yet")
        XCTAssertFalse(store.perform(.pause(reason: " ")).ok)
        XCTAssertTrue(store.perform(.pause(reason: "Standup")).ok)
        XCTAssertEqual(store.workLog?.intervals.last?.reason, "Standup")
        XCTAssertFalse(store.perform(.pause(reason: "Again")).ok)
        XCTAssertTrue(store.perform(.resume).ok)
        XCTAssertFalse(store.perform(.resume).ok, "already working")

        let index = store.journal.sessions.count - 1
        store.journal.sessions[index].intervals[store.journal.sessions[index].intervals.count - 1].start = Date().addingTimeInterval(-3600)
        let reply = store.perform(.takeBreak)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(store.workLog?.phase, .break)
    }

    @MainActor func testTasksDuringASession() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "First")]
        store.start()
        XCTAssertTrue(store.perform(.addTask(title: "Second", link: "https://linear.app/a/issue/B-2")).ok)
        let ids = try XCTUnwrap(store.workLog?.todos.map(\.id))
        XCTAssertTrue(store.perform(.setTaskCompleted(id: ids[1], completed: true)).ok)
        XCTAssertEqual(store.workLog?.todos[1].completed, true)
        XCTAssertTrue(store.perform(.updateTask(id: ids[1], title: "Second, renamed", link: nil)).ok)
        XCTAssertEqual(store.workLog?.todos[1].link, "https://linear.app/a/issue/B-2", "a title alone keeps the link")
        XCTAssertTrue(store.perform(.updateTask(id: ids[1], title: nil, link: "https://github.com/a/b/pull/3")).ok)
        XCTAssertEqual(store.workLog?.todos[1].title, "Second, renamed", "a link alone keeps the title")
        XCTAssertEqual(store.workLog?.todos[1].link, "https://github.com/a/b/pull/3")
        XCTAssertFalse(store.perform(.updateTask(id: ids[1], title: nil, link: "nope")).ok)
        XCTAssertTrue(store.perform(.deleteTask(id: ids[0])).ok)
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Second, renamed"])
        XCTAssertFalse(store.perform(.deleteTask(id: UUID())).ok)
    }

    @MainActor func testFinishAndEnd() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Task")]
        store.journal.hours = 1
        store.start()
        let early = store.perform(.finish)
        XCTAssertFalse(early.ok)
        XCTAssertTrue(early.message.contains("lockin end"), early.message)
        XCTAssertFalse(store.perform(.end(reason: "")).ok)
        XCTAssertTrue(store.perform(.end(reason: "Starting a new day")).ok)
        XCTAssertFalse(store.active)
        XCTAssertFalse(store.perform(.addTask(title: "Lost", link: "")).ok, "the review would overwrite the plan")
        XCTAssertFalse(store.perform(.start(hours: nil)).ok, "review first")
    }

    @MainActor func testHardcoreRefusesEnd() {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Task")]
        store.lockSession = true
        store.start()
        XCTAssertFalse(store.perform(.end(reason: "Bored")).ok)
        XCTAssertTrue(store.active)
    }

    @MainActor func testBackfillAndUndo() {
        let store = makeStore()
        // Whole seconds: saved timestamps keep microseconds, so an arbitrary Date() reloads within a microsecond, not exactly.
        let end = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down)), start = end.addingTimeInterval(-1800)
        XCTAssertFalse(store.perform(.backfill(start: end, end: start)).ok, "the range ends before it starts")
        XCTAssertTrue(store.journal.sessions.isEmpty)
        XCTAssertTrue(store.perform(.backfill(start: start, end: end)).ok)
        XCTAssertEqual(makeStore().journal.sessions.map(\.startedAt), [start], "the backfill is saved as a new session")
        XCTAssertFalse(store.perform(.backfill(start: start, end: end)).ok, "already recorded")
        XCTAssertEqual(store.journal.sessions.count, 1, "a refused backfill leaves the journal as it was")
        XCTAssertTrue(store.perform(.undoBackfill).ok)
        XCTAssertTrue(makeStore().journal.sessions.isEmpty, "the undo is saved")
        XCTAssertFalse(store.perform(.undoBackfill).ok, "nothing left to undo")
    }

    @MainActor func testEventsAreRecordedOnTheRunningSession() throws {
        let store = makeStore()
        XCTAssertFalse(store.perform(.addEvent(text: "Too early")).ok, "no session yet")
        store.journal.draft = [Todo(title: "Task")]
        store.start()
        XCTAssertFalse(store.perform(.addEvent(text: "  ")).ok)
        XCTAssertTrue(store.perform(.pause(reason: "Lunch")).ok)
        let reply = store.perform(.addEvent(text: " Deployed to staging "))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(reply.message, "Recorded “Deployed to staging”.")
        XCTAssertEqual(makeStore().workLog?.events.map(\.text), ["Deployed to staging"], "events are saved, paused or not")
    }

    @MainActor func testDeletingFromThePlan() throws {
        let store = makeStore()
        XCTAssertTrue(store.perform(.addTask(title: "Only", link: "")).ok)
        let id = try XCTUnwrap(store.journal.draft.first?.id)
        XCTAssertFalse(store.perform(.updateTask(id: id, title: " ", link: nil)).ok, "a task needs a title")
        XCTAssertFalse(store.perform(.deleteTask(id: UUID())).ok)
        XCTAssertTrue(store.perform(.deleteTask(id: id)).ok)
        XCTAssertEqual(makeStore().journal.draft.count, 1, "the planner keeps a blank row")
        XCTAssertFalse(makeStore().journal.draft[0].hasTitle)
    }

    @MainActor func testUnsavedChangesAreRolledBack() throws {
        let store = makeStore()
        // A file where the sessions directory should be makes every write fail.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: Storage.sessionsDirectory(in: directory))
        let reply = store.perform(.addTask(title: "Lost", link: ""))
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.message.contains("Could not save"), reply.message)
        XCTAssertFalse(store.journal.draft.contains { $0.title == "Lost" }, "the journal in memory matches the one on disk")
    }
}

/// The notification round trip the CLI uses, against a listening store with its own temporary journal.
final class RemoteChannelTests: XCTestCase {
    @MainActor func testRequestGetsAReply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A channel of its own: on the app's channel, a running Lock In would get this task too.
        let channel = RemoteChannel(name: "app.lockin.mac.tests.\(UUID().uuidString)")
        let store = Store(directory: directory, runTimer: false, enforceBlocking: false, channel: channel)
        // Stands in for a running Lock In: listening on another channel, it must not hear this one.
        let bystander = Store(directory: directory.appendingPathComponent("bystander"), runTimer: false, enforceBlocking: false,
                              channel: RemoteChannel(name: "app.lockin.mac.tests.\(UUID().uuidString)"))
        let center = DistributedNotificationCenter.default()
        let id = UUID().uuidString
        let replied = expectation(description: "reply")
        var reply: RemoteReply?
        let observer = center.addObserver(forName: channel.reply, object: id, queue: .main) { note in
            reply = RemoteChannel.decode(RemoteReply.self, from: note.userInfo); replied.fulfill()
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(channel.request, object: id, userInfo: RemoteChannel.encode(RemoteCommand.addTask(title: "Via CLI", link: "")), deliverImmediately: true)
        wait(for: [replied], timeout: 5)
        XCTAssertEqual(reply?.ok, true, reply?.message ?? "no reply")
        XCTAssertEqual(store.journal.draft.map(\.title), ["Via CLI"])
        XCTAssertFalse(bystander.journal.draft.contains { $0.title == "Via CLI" }, "other channels don't hear it")
    }
}
