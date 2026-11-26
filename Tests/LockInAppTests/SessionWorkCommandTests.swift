import XCTest
import LockInCore
@testable import LockIn

final class SessionWorkCommandTests: XCTestCase {
    @MainActor func testDuplicateNamesRejectWithoutChangingSessionOrDisk() throws {
        let store = store()
        try store.addWork("Plan the rollout")
        let graph = store.workGraph
        let tasks = store.graphSessionTasks
        for input in ["Plan the rollout", "plan THE rollout", "  Plan the rollout\n"] {
            XCTAssertThrowsError(try store.addWork(input)) {
                XCTAssertEqual($0.localizedDescription, "This task is already in the session.")
            }
        }
        XCTAssertEqual(store.workGraph, graph)
        XCTAssertEqual(store.graphSessionTasks, tasks)
        XCTAssertEqual(self.store().workGraph, graph)
    }

    @MainActor func testAddWorkRejectsEquivalentSelectedLinksWithoutMutation() throws {
        let store = store()
        let nodes = [
            WorkNode(id: "linear:1", kind: .linear, title: "Issue", url: "https://linear.app/team/issue/ENG-1/old-title"),
            WorkNode(id: "github:org/repo#12", kind: .pullRequest, title: "PR", url: "https://github.com/org/repo/pull/12")
        ]
        XCTAssertTrue(store.editWorkGraph { $0.nodes = nodes })
        XCTAssertTrue(store.selectWorkForSession(nodes))
        let before = store.graphSessionTasks
        for input in ["ENG-1", "https://linear.app/team/issue/ENG-1/new-title", "https://github.com/ORG/REPO/pull/12/files#diff"] {
            XCTAssertThrowsError(try store.addWork(input)) {
                XCTAssertEqual($0.localizedDescription, "This link is already in the session.")
            }
        }
        XCTAssertEqual(store.graphSessionTasks, before)
        XCTAssertFalse(store.workImporting)
    }

    @MainActor func testAddWorkCreatesNamesAndLinksAndReusesSavedLinks() throws {
        let store = store()
        try store.addWork("Plan the rollout")
        try store.addWork("https://example.com/")
        XCTAssertEqual(store.graphSessionTasks.count, 2)
        XCTAssertThrowsError(try store.addWork("https://EXAMPLE.com:443/#section"))
        let linked = try XCTUnwrap(store.graphSessionTasks.first { !$0.link.isEmpty })
        store.removeWorkFromSession(linked.workIdentity)
        try store.addWork("https://example.com")
        XCTAssertEqual(store.workGraph.nodes.count, 2)
        XCTAssertTrue(store.sessionWorkIDs.contains(linked.workIdentity))
        XCTAssertThrowsError(try store.addWork("https://"))
    }

    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    @MainActor private func store() -> Store { Store(directory: directory, runTimer: false, enforceBlocking: false, channel: nil) }

    @MainActor func testCompletionAndRenameUseActiveSessionWithoutChangingDraftOrSource() {
        let store = store()
        let draft = Todo(title: "Next session")
        let remote = WorkNode(id: "pr", kind: .pullRequest, title: "Remote title", status: "Passing")
        var task = Todo(title: remote.title)
        task.workNodeID = remote.id
        XCTAssertTrue(store.editWorkGraph { $0.nodes = [remote] })
        store.commitJournal {
            $0.setPlan([draft])
            $0.sessions.append(WorkLog(todos: [task], targetSeconds: 60, now: Date()))
        }
        store.setSessionWorkDone(remote.id, done: true)
        store.renameSessionWork(remote.id, title: "Session title", link: "")
        XCTAssertTrue(store.isSessionWorkDone(remote.id))
        XCTAssertFalse(store.isSessionWorkDone("unknown"))
        XCTAssertEqual(store.graphSessionTasks.first?.title, "Remote title")
        XCTAssertEqual(store.journal.draft, [draft])
        XCTAssertEqual(store.workGraph.nodes.first { $0.id == remote.id }, remote)
    }
}
