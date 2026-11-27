import XCTest
import LockInCore
@testable import LockIn

final class SessionFlowTests: StoreTestCase {
    /// A session's file as saved.
    private func sessionFile(_ id: UUID) throws -> SessionFile {
        try FileFormat.decode(SessionFile.self, from: Data(contentsOf: sessionURL(id)), supported: FileFormat.sessionVersion)
    }
    /// Where a session is saved: file names come from start times, so this looks the session up by its id.
    private func sessionURL(_ id: UUID) throws -> URL {
        try XCTUnwrap(try Storage.load(from: directory).sessionFiles[id], "no file for session \(id)")
    }
    @MainActor func testEmptySessionPersistsAndRequiresReviewBeforeRestarting() throws {
        let store = makeStore()
        store.start()
        XCTAssertTrue(store.active)
        let id = try XCTUnwrap(store.workLog?.id)
        XCTAssertTrue(try sessionFile(id).tasks.isEmpty)
        XCTAssertEqual(makeStore().workLog?.id, id)
        store.endSession(reason: "Done")
        store.start()
        XCTAssertFalse(store.active)
        XCTAssertEqual(store.journal.pendingReviewID, id)
        store.completeReview()
        store.start()
        XCTAssertTrue(store.active)
        XCTAssertNotEqual(store.workLog?.id, id)
    }

    @MainActor func testPlanPauseCompletionReviewAndDiskJournal() async throws {
        let store = makeStore()
        store.journal.draft = [Todo(title: "Test TODO")]
        store.journal.hours = 1
        store.start()
        XCTAssertTrue(store.active)
        let id = try XCTUnwrap(store.workLog?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try sessionURL(id).path))
        store.pause(reason: "  ")
        XCTAssertEqual(store.workLog?.phase, .work)
        store.pause(reason: "Meeting")
        XCTAssertEqual(store.workLog?.phase, .pause)
        XCTAssertEqual(try sessionFile(id).intervals.last?.reason, "Meeting")
        store.resume()
        let index = store.journal.sessions.count - 1
        advance(store, by: 3601)
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
        let saved = try sessionFile(id)
        XCTAssertTrue(saved.finishedNaturally)
        XCTAssertTrue(saved.reviewed)
        XCTAssertEqual(saved.tasks.first?.rollIntoNextSession, true)
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
        let saved = try sessionFile(id)
        XCTAssertFalse(saved.finishedNaturally)
        XCTAssertEqual(saved.endReason, "Starting a new day")
        store.journal.sessions[0].todos[0].rollForward = true
        store.completeReview()
        XCTAssertEqual(store.journal.draft.map(\.title), ["Yesterday's task"])
        store.start()
        XCTAssertTrue(store.active)
        XCTAssertNotEqual(store.workLog?.id, id)
    }
    @MainActor func testStartNewDayIsBlockedInHardcoreMode() throws {
        let store = startedStore(tasks: ["Locked"], hardcore: true)
        store.endSession(reason: "Starting a new day")
        XCTAssertTrue(store.active)
        XCTAssertNotNil(store.workLog)
    }
    @MainActor func testHardcoreAllowsPausesButNotQuitting() throws {
        let store = startedStore(tasks: ["Locked"], hardcore: true)
        XCTAssertFalse(store.shouldQuit())
        XCTAssertEqual(store.message, Store.hardcoreQuitMessage)
        XCTAssertFalse(store.showPause)
        for request in [{ store.toggleFocus() }, { store.handleURL(URL(string: "lockin://pause")!) }] {
            store.showPause = false
            request()
            XCTAssertTrue(store.showPause, "a pause is recorded, so Hardcore Mode allows it")
        }
        store.pause(reason: "Fire alarm")
        XCTAssertEqual(store.workLog?.phase, .pause)
        XCTAssertFalse(store.shouldQuit(), "Hardcore Mode holds until the target, paused or not")
    }
    @MainActor func testQuittingAsksForAPauseReasonFirst() throws {
        let store = startedStore(tasks: ["Work"])
        XCTAssertFalse(store.shouldQuit())
        XCTAssertTrue(store.showPause)
        store.pause(reason: "Done for now")
        XCTAssertTrue(store.shouldQuit())
    }
    @MainActor func testFinishIsRefusedBeforeTheTarget() throws {
        let store = startedStore(tasks: ["Work"])
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
        advance(store, by: 3601)
        XCTAssertEqual(store.workLog?.phase, .overtime)
        XCTAssertFalse(store.locked, "the target is met, so Hardcore Mode no longer holds")
        store.finishSession()
        XCTAssertFalse(store.active)
        XCTAssertTrue(try XCTUnwrap(store.journal.sessions.last).finishedNaturally)
    }
    @MainActor func testTasksCanBeAddedMidSession() throws {
        let store = startedStore(tasks: ["Planned"])
        let id = try XCTUnwrap(store.workLog?.id)
        XCTAssertThrowsError(try store.addWork("   "))
        XCTAssertThrowsError(try store.addWork(WorkInput(title: "Bad link", link: "notaurl")))
        try store.addWork("  Surprise bug - https://example.com/task  ")
        store.pause(reason: "Lunch")
        try store.addWork("Added while paused")
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Planned", "Surprise bug", "Added while paused"])
        let saved = try sessionFile(id)
        XCTAssertEqual(saved.tasks[1].title, "Surprise bug")
        XCTAssertEqual(saved.tasks[1].link, "https://example.com/task")
        let restored = makeStore()
        XCTAssertEqual(restored.workLog?.todos.count, 3)
    }
    @MainActor func testTasksCanBeEditedMidSession() throws {
        let store = startedStore(tasks: ["Typo taks"])
        let task = try XCTUnwrap(store.workLog?.todos.first)
        XCTAssertThrowsError(try store.renameWork(task.workIdentity, title: "  ", link: ""))
        XCTAssertThrowsError(try store.renameWork(task.workIdentity, title: "Fixed", link: "ftp://example.com/file"))
        XCTAssertEqual(store.workLog?.todos.first?.title, "Typo taks")
        XCTAssertThrowsError(try store.renameWork(WorkNode.localID(), title: "Unknown", link: ""))
        try store.renameWork(task.workIdentity, title: " Fixed task ", link: "https://linear.app/acme/issue/ABC-2")
        let edited = try XCTUnwrap(store.workLog?.todos.first)
        XCTAssertEqual(edited.id, task.id, "editing keeps the task's identity")
        XCTAssertEqual(edited.title, "Fixed task")
        XCTAssertEqual(edited.link, "https://linear.app/acme/issue/ABC-2")
        let restored = makeStore()
        XCTAssertEqual(restored.workLog?.todos.first?.title, "Fixed task")
    }
    @MainActor func testUpdatePausesQuitsAndResumesOnRelaunch() throws {
        let store = makeStore()
        let quits = countQuits(of: store)
        store.journal.draft = [Todo(title: "Work")]
        store.start()
        store.handleURL(URL(string: "lockin://update")!)
        XCTAssertEqual(quits(), 1)
        XCTAssertEqual(store.workLog?.phase, .pause)
        XCTAssertEqual(store.workLog?.intervals.last?.reason, "Updating Lock In")
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.workLog?.phase, .work)
        XCTAssertNil(relaunched.journal.resumeAfterUpdateID)
        XCTAssertEqual(relaunched.workLog?.intervals.filter { $0.kind == .pause }.count, 1)
    }
    @MainActor func testRelaunchCountsTimeTheAppWasNotRunningAsAPause() throws {
        let store = startedStore(tasks: ["Work"])
        let started = clock.now
        clock.advance(by: 15)
        let quick = makeStore()
        XCTAssertEqual(quick.workLog?.phase, .work, "a relaunch within 15 seconds picks up where it left off")
        XCTAssertEqual(quick.workLog?.intervals.count, 1)
        // That relaunch saved a fresh checkpoint, so the gap is measured from it.
        clock.advance(by: 16)
        let late = try XCTUnwrap(makeStore().workLog)
        XCTAssertEqual(late.phase, .pause)
        let pause = try XCTUnwrap(late.intervals.last)
        XCTAssertEqual(pause.reason, "App was not running; resumed from saved checkpoint")
        XCTAssertEqual(pause.start, started.addingTimeInterval(15))
        XCTAssertEqual(late.worked(at: clock.now), 15, "time away earns no credit")
    }
    @MainActor func testUpdateLeavesYourOwnPauseAlone() throws {
        let store = makeStore()
        let quits = countQuits(of: store)
        store.journal.draft = [Todo(title: "Work")]
        store.start()
        store.pause(reason: "Lunch")
        store.quitForUpdate()
        XCTAssertEqual(quits(), 1)
        XCTAssertNil(store.journal.resumeAfterUpdateID)
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.workLog?.phase, .pause)
        XCTAssertEqual(relaunched.workLog?.intervals.last?.reason, "Lunch")
    }
    @MainActor func testUpdateIsRefusedInHardcoreMode() throws {
        let store = makeStore()
        let quits = countQuits(of: store)
        store.journal.draft = [Todo(title: "Work")]
        store.lockSession = true
        store.start()
        store.quitForUpdate()
        XCTAssertEqual(quits(), 0)
        XCTAssertEqual(store.workLog?.phase, .work)
        XCTAssertNotNil(store.message)
    }
    @MainActor func testReviewEditsAreSavedOrRolledBack() throws {
        let store = startedStore(tasks: ["Ship"])
        store.endSession(reason: "Done for today")
        store.reviewTasks[0].rollForward = true
        XCTAssertEqual(makeStore().reviewTasks.first?.rollForward, true, "review edits are saved as they're made")
        // A file where the sessions directory should be makes every write fail.
        try FileManager.default.removeItem(at: Storage.sessionsDirectory(in: directory))
        try Data().write(to: Storage.sessionsDirectory(in: directory))
        store.reviewTasks.append(Todo(title: "Lost"))
        XCTAssertEqual(store.reviewTasks.map(\.title), ["Ship"], "the review on screen matches the one on disk")
        XCTAssertNotNil(store.message)
    }
    @MainActor func testTasksCanBeDeletedMidSession() throws {
        let store = startedStore(tasks: ["Keep", "Drop"])
        let drop = try XCTUnwrap(store.workLog?.todos.last)
        XCTAssertThrowsError(try store.removeWork(WorkNode.localID()))
        try store.removeWork(drop.workIdentity)
        XCTAssertEqual(store.workLog?.todos.map(\.title), ["Keep"])
        XCTAssertEqual(makeStore().workLog?.todos.map(\.title), ["Keep"], "the deletion is saved")
    }
    @MainActor func testFinishedSessionsAreNotRewrittenOnEveryCheckpoint() throws {
        let store = startedStore(tasks: ["First"])
        let id = try XCTUnwrap(store.workLog?.id)
        store.endSession(reason: "Done")
        store.completeReview()
        let file = try sessionURL(id)
        try "edited elsewhere".write(to: file, atomically: true, encoding: .utf8)
        store.journal.draft = [Todo(title: "Second")]
        store.start()
        store.persist()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited elsewhere", "an unchanged session is skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try sessionURL(try XCTUnwrap(store.workLog?.id)).path))
    }
    @MainActor func testTasksCanBeTickedOffMidSession() throws {
        let store = startedStore(tasks: ["Ship"])
        let task = try XCTUnwrap(store.workLog?.todos.first)
        XCTAssertThrowsError(try store.setWorkDone(WorkNode.localID(), done: true))
        try store.setWorkDone(task.workIdentity, done: true)
        XCTAssertEqual(store.workLog?.todos.first?.completed, true)
        XCTAssertEqual(makeStore().workLog?.todos.first?.completed, true, "the tick is saved")
        try store.setWorkDone(task.workIdentity, done: false)
        XCTAssertEqual(store.workLog?.todos.first?.completed, false)
    }
    @MainActor func testWakingResumesWhatSleepPaused() throws {
        let store = startedStore(tasks: ["Task"])
        store.pauseForSleep()
        XCTAssertEqual(store.workLog?.intervals.last?.reason, "Mac went to sleep")
        store.resumeAfterWake()
        XCTAssertEqual(store.workLog?.phase, .work)

        // A break interrupted by sleep is a break again on waking, while break time is left.
        advance(store, by: 3600)
        store.takeBreak()
        store.pauseForSleep()
        store.resumeAfterWake()
        XCTAssertEqual(store.workLog?.phase, .break)
    }
    @MainActor func testUnreadableSettingsAreNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = Storage.settingsFile(in: directory)
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertNotNil(store.message)
        store.journal.draft = [Todo(title: "Task")]
        store.start()
        XCTAssertFalse(store.active, "nothing starts that couldn't be saved")
        store.persist()
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
    }
    @MainActor func testWakingLeavesOtherPausesAlone() throws {
        let store = startedStore(tasks: ["Task"])
        store.pause(reason: "Lunch")
        store.pauseForSleep()
        store.resumeAfterWake()
        XCTAssertEqual(store.workLog?.phase, .pause, "your own pause isn't resumed")

        store.resume()
        store.pauseForSleep()
        store.resume()
        store.pause(reason: "Changed my mind")
        store.resumeAfterWake()
        XCTAssertEqual(store.workLog?.intervals.last?.reason, "Changed my mind", "a pause made after sleep is left alone")
    }
}
