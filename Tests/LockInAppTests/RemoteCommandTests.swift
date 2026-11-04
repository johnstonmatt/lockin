import XCTest
import LockInCore
@testable import LockIn

/// `Store.perform`, which carries out `lockin` CLI commands.
final class RemoteCommandTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    @MainActor private func makeStore() -> Store {
        Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false, listen: false)
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
}

/// The notification round trip the CLI uses, against a listening store with its own temporary journal.
final class RemoteChannelTests: XCTestCase {
    @MainActor func testRequestGetsAReply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false)
        let center = DistributedNotificationCenter.default()
        let id = UUID().uuidString
        let replied = expectation(description: "reply")
        var reply: RemoteReply?
        let observer = center.addObserver(forName: RemoteChannel.reply, object: id, queue: .main) { note in
            reply = RemoteChannel.decode(RemoteReply.self, from: note.userInfo); replied.fulfill()
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(RemoteChannel.request, object: id, userInfo: RemoteChannel.encode(RemoteCommand.addTask(title: "Via CLI", link: "")), deliverImmediately: true)
        wait(for: [replied], timeout: 5)
        XCTAssertEqual(reply?.ok, true, reply?.message ?? "no reply")
        XCTAssertEqual(store.journal.draft.map(\.title), ["Via CLI"])
    }
}
