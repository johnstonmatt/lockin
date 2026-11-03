import XCTest
import LockInCore
@testable import LockIn

final class SessionFlowTests: XCTestCase {
    @MainActor func testPlanPauseCompletionReviewAndDiskJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false)
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
        let restored = Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false)
        XCTAssertEqual(restored.journal.draft[0].title, "Finish next time")
        XCTAssertEqual(restored.journal.sessions.count, 1)
        XCTAssertFalse(restored.active)
    }
    @MainActor func testStartNewDayEndsSessionEarlyAndAllowsANewOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(stateFile: directory.appendingPathComponent("preferences.json"), journalDirectory: directory, runTimer: false, enforceBlocking: false)
        store.journal.draft = [Todo(title: "Locked")]
        store.lockSession = true
        store.start()
        store.endSession(reason: "Starting a new day")
        XCTAssertTrue(store.active)
        XCTAssertNotNil(store.workLog)
    }
}
