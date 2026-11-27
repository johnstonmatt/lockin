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

        let index = store.journal.sessions.count - 1
        store.journal.sessions[index].intervals[store.journal.sessions[index].intervals.count - 1].start = Date().addingTimeInterval(-3600)
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
        // Whole seconds: saved timestamps keep microseconds, so an arbitrary Date() reloads within a microsecond, not exactly.
        let end = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down)), start = end.addingTimeInterval(-1800)
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
}

/// The notification round trip the CLI uses, against a listening store with its own temporary journal.
final class RemoteChannelTests: XCTestCase {
    @MainActor func testRequestGetsAReply() async throws {
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
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(reply?.ok, true, reply?.message ?? "no reply")
        XCTAssertEqual(store.journal.draft.map(\.title), ["Via CLI"])
        XCTAssertFalse(bystander.journal.draft.contains { $0.title == "Via CLI" }, "other channels don't hear it")
    }
}
