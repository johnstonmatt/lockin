import XCTest
import LockInCore
@testable import LockIn

final class SessionFlowTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    /// A store backed by this test's temporary directory; calling it again simulates relaunching the app.
    @MainActor private func makeStore() -> Store {
        Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false)
    }
    @MainActor func testPlanPauseCompletionReviewAndDiskJournal() async throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Test TODO")]
        store.journal.hours = 1
        store.start()
        XCTAssertTrue(store.active)
        let id = try XCTUnwrap(store.workLog?.id)
        let yamlFile = directory.appendingPathComponent("session-\(id).yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: yamlFile.path))
        store.pause(reason: "  ")
        XCTAssertEqual(store.workLog?.phase, .work)
        store.pause(reason: "Meeting")
        XCTAssertEqual(store.workLog?.phase, .pause)
        XCTAssertTrue(try String(contentsOf: yamlFile, encoding: .utf8).contains("reason: \"Meeting\""))
        store.resume()
        // Advance the work interval without waiting or running browser automation.
        let index = store.journal.sessions.count - 1
        let last = store.journal.sessions[index].intervals.count - 1
        store.journal.sessions[index].intervals[last].start = Date().addingTimeInterval(-3601)
        store.tick()
        XCTAssertTrue(store.active, "reaching the target starts overtime")
        XCTAssertEqual(store.workLog?.phase, .overtime)
        XCTAssertTrue(store.timerText.hasPrefix("+"))
        store.finishSession()
        XCTAssertFalse(store.active)
        XCTAssertTrue(store.showReview)
        XCTAssertEqual(store.journal.pendingReviewID, id)
        store.journal.sessions[index].todos[0].title = "Finish next time"
        store.journal.sessions[index].todos[0].rollForward = true
        store.completeReview()
        XCTAssertNil(store.journal.pendingReviewID)
        XCTAssertEqual(store.journal.draft[0].title, "Finish next time")
        XCTAssertNotNil(store.journal.draft[0].sourceTodoID)
        let yaml = try String(contentsOf: yamlFile, encoding: .utf8)
        XCTAssertTrue(yaml.contains("finished_naturally: true"))
        XCTAssertTrue(yaml.contains("reviewed: true"))
        XCTAssertTrue(yaml.contains("roll_into_next_session: true"))
        let restored = makeStore()
        XCTAssertEqual(restored.journal.draft[0].title, "Finish next time")
        XCTAssertEqual(restored.journal.sessions.count, 1)
        XCTAssertFalse(restored.active)
    }
    @MainActor func testStartNewDayEndsSessionEarlyAndAllowsANewOne() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Yesterday's task")]
        store.journal.hours = 4
        store.start()
        let id = try XCTUnwrap(store.workLog?.id)
        store.pause(reason: "End of day")
        store.endSession(reason: "")
        XCTAssertTrue(store.active, "blank reason must not end the session")
        store.endSession(reason: "Starting a new day")
        XCTAssertFalse(store.active)
        XCTAssertNil(store.workLog)
        XCTAssertEqual(store.journal.pendingReviewID, id)
        XCTAssertTrue(store.showReview)
        let yaml = try String(contentsOf: directory.appendingPathComponent("session-\(id).yaml"), encoding: .utf8)
        XCTAssertTrue(yaml.contains("finished_naturally: false"))
        XCTAssertTrue(yaml.contains("end_reason: \"Starting a new day\""))
        store.journal.sessions[0].todos[0].rollForward = true
        store.completeReview()
        XCTAssertEqual(store.journal.draft.map(\.title), ["Yesterday's task"])
        store.start()
        XCTAssertTrue(store.active)
        XCTAssertNotEqual(store.workLog?.id, id)
    }
    @MainActor func testStartNewDayIsBlockedInHardcoreMode() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Locked")]
        store.lockSession = true
        store.start()
        store.endSession(reason: "Starting a new day")
        XCTAssertTrue(store.active)
        XCTAssertNotNil(store.workLog)
    }
    @MainActor func testFinishIsRefusedBeforeTheTarget() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Work")]
        store.start()
        store.finishSession()
        XCTAssertTrue(store.active)
        XCTAssertEqual(store.workLog?.phase, .work)
    }
    @MainActor func testHardcoreLiftsInOvertime() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Locked")]
        store.journal.hours = 1
        store.lockSession = true
        store.start()
        XCTAssertTrue(store.locked)
        let index = store.journal.sessions.count - 1
        store.journal.sessions[index].intervals[0].start = Date().addingTimeInterval(-3601)
        store.tick()
        XCTAssertEqual(store.workLog?.phase, .overtime)
        XCTAssertFalse(store.locked, "the target is met, so Hardcore Mode no longer holds")
        store.finishSession()
        XCTAssertFalse(store.active)
        XCTAssertTrue(try XCTUnwrap(store.journal.sessions.last).finishedNaturally)
    }
    @MainActor func testTasksCanBeAddedMidSession() throws {
        let store = makeStore()
        XCTAssertFalse(store.addTask(title: "No session yet"))
        store.journal.draft = [Todo(title: "Planned")]
        store.start()
        let id = try XCTUnwrap(store.workLog?.id)
        XCTAssertFalse(store.addTask(title: "   "))
        XCTAssertFalse(store.addTask(title: "Bad link", link: "notaurl"))
        XCTAssertTrue(store.addTask(title: "  Surprise bug  ", link: "https://linear.app/acme/issue/ABC-1"))
        store.pause(reason: "Lunch")
        XCTAssertTrue(store.addTask(title: "Added while paused"))
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Planned", "Surprise bug", "Added while paused"])
        let yaml = try String(contentsOf: directory.appendingPathComponent("session-\(id).yaml"), encoding: .utf8)
        XCTAssertTrue(yaml.contains("title: \"Surprise bug\""))
        XCTAssertTrue(yaml.contains("linear.app\\/acme\\/issue\\/ABC-1"), "JSON-quoted YAML escapes slashes")
        let restored = makeStore()
        XCTAssertEqual(restored.workLog?.todos.count, 3)
    }
    @MainActor func testTasksCanBeEditedMidSession() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Typo taks")]
        store.start()
        let task = try XCTUnwrap(store.workLog?.todos.first)
        XCTAssertFalse(store.updateTask(id: task.id, title: "  ", link: ""))
        XCTAssertFalse(store.updateTask(id: task.id, title: "Fixed", link: "ftp://example.com/file"))
        XCTAssertEqual(store.workLog?.todos.first?.title, "Typo taks")
        XCTAssertFalse(store.updateTask(id: UUID(), title: "Unknown", link: ""))
        XCTAssertTrue(store.updateTask(id: task.id, title: " Fixed task ", link: "https://linear.app/acme/issue/ABC-2"))
        let edited = try XCTUnwrap(store.workLog?.todos.first)
        XCTAssertEqual(edited.id, task.id, "editing keeps the task's identity")
        XCTAssertEqual(edited.title, "Fixed task")
        XCTAssertEqual(edited.link, "https://linear.app/acme/issue/ABC-2")
        let restored = makeStore()
        XCTAssertEqual(restored.workLog?.todos.first?.title, "Fixed task")
    }
    @MainActor func testUpdatePausesQuitsAndResumesOnRelaunch() throws {
        let store = makeStore()
        var quits = 0; store.terminate = { quits += 1 }
        store.journal.draft = [Todo(title: "Work")]
        store.start()
        store.handleURL(URL(string: "lockin://update")!)
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(store.workLog?.phase, .pause)
        XCTAssertEqual(store.workLog?.intervals.last?.reason, "Updating Lock In")
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.workLog?.phase, .work)
        XCTAssertNil(relaunched.journal.resumeAfterUpdateID)
        XCTAssertEqual(relaunched.workLog?.intervals.filter { $0.kind == .pause }.count, 1)
    }
    @MainActor func testUpdateLeavesYourOwnPauseAlone() throws {
        let store = makeStore()
        var quits = 0; store.terminate = { quits += 1 }
        store.journal.draft = [Todo(title: "Work")]
        store.start()
        store.pause(reason: "Lunch")
        store.quitForUpdate()
        XCTAssertEqual(quits, 1)
        XCTAssertNil(store.journal.resumeAfterUpdateID)
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.workLog?.phase, .pause)
        XCTAssertEqual(relaunched.workLog?.intervals.last?.reason, "Lunch")
    }
    @MainActor func testUpdateIsRefusedInHardcoreMode() throws {
        let store = makeStore()
        var quits = 0; store.terminate = { quits += 1 }
        store.journal.draft = [Todo(title: "Work")]
        store.lockSession = true
        store.start()
        store.quitForUpdate()
        XCTAssertEqual(quits, 0)
        XCTAssertEqual(store.workLog?.phase, .work)
        XCTAssertNotNil(store.message)
    }
    @MainActor func testTasksCanBeDeletedMidSession() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Keep"), Todo(title: "Drop")]
        store.start()
        let drop = try XCTUnwrap(store.workLog?.todos.last)
        XCTAssertFalse(store.deleteTask(id: UUID()))
        XCTAssertTrue(store.deleteTask(id: drop.id))
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Keep"])
        XCTAssertEqual(makeStore().workLog?.todos.map(\.title), ["Keep"], "the deletion is saved")
    }
    @MainActor func testFinishedSessionsAreNotRewrittenOnEveryCheckpoint() throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "First")]
        store.start()
        let id = try XCTUnwrap(store.workLog?.id)
        store.endSession(reason: "Done")
        store.completeReview()
        let file = directory.appendingPathComponent("session-\(id).yaml")
        try "edited elsewhere".write(to: file, atomically: true, encoding: .utf8)
        store.journal.draft = [Todo(title: "Second")]
        store.start()
        store.saveAll()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited elsewhere", "an unchanged session is skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session-\(try XCTUnwrap(store.workLog?.id)).yaml").path))
    }
}
