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

    @MainActor func testCLIAddsLocalWorkAndUsesUIDuplicateChecks() async throws {
        let store = store()
        let added = await store.perform(.addTask(title: "Plan the rollout", link: ""))
        XCTAssertTrue(added.ok, added.message)
        let duplicate = await store.perform(.addTask(title: "PLAN the rollout", link: ""))
        XCTAssertFalse(duplicate.ok)
        XCTAssertEqual(duplicate.message, "This task is already in the session.")
        let linked = await store.perform(.addTask(title: "Reference", link: "https://example.com"))
        XCTAssertTrue(linked.ok)
        XCTAssertEqual(store.sessionGraph.nodes.first { $0.url == "https://example.com" }?.title, "Reference")
        XCTAssertEqual(store.graphSessionTasks.count, 2)
        XCTAssertEqual(self.store().sessionGraph, store.sessionGraph)
    }

    @MainActor func testCLIImportsLinearDependenciesAndRefreshesSavedWork() async throws {
        let store = store()
        let issue = WorkNode(id: "linear:ENG-1", kind: .linear, title: "Feature", url: "https://linear.app/team/issue/ENG-1")
        let child = WorkNode(id: "github:org/repo#12", kind: .pullRequest, title: "Implementation", url: "https://github.com/org/repo/pull/12")
        let result = WorkImportResult(nodes: [issue, child], snapshot: WorkImport(id: issue.id, url: issue.url,
            nodeIDs: [issue.id, child.id], edges: [WorkEdge(from: issue.id, to: child.id, kind: .implements, source: .linear)]))
        let importer = WorkImporter(fetchLinear: { input in
            XCTAssertEqual(input, "ENG-1")
            return result
        }, enrichGitHub: { $0 })
        let reply = await store.perform(.addTask(title: "ENG-1", link: ""), using: importer)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertFalse(store.workImporting)
        XCTAssertEqual(store.sessionWorkIDs, [issue.id])
        XCTAssertEqual(Set(store.sessionGraph.nodes.map(\.id)), [issue.id, child.id])
        let duplicate = await store.perform(.addTask(title: child.title, link: child.url), using: importer)
        XCTAssertFalse(duplicate.ok)
        XCTAssertTrue(duplicate.message.contains("Already included through"))

        store.removeWorkFromSession(issue.id)
        var refreshed = result
        refreshed.nodes[1].resolved = true
        let updated = refreshed
        let refresh = WorkImporter(fetchLinear: { _ in updated }, enrichGitHub: { $0 })
        let addedAgain = await store.perform(.addTask(title: issue.title, link: issue.url), using: refresh)
        XCTAssertTrue(addedAgain.ok, addedAgain.message)
        XCTAssertEqual(store.sessionGraph.nodes.first { $0.id == child.id }?.resolved, true)
        XCTAssertEqual(self.store().sessionGraph, store.sessionGraph)
    }

    @MainActor func testCLIImportsGitHubIntoActiveSession() async {
        let store = store()
        store.start()
        let importer = WorkImporter(fetchLinear: { _ in throw WorkImportError("Unexpected Linear request") }, enrichGitHub: { seed in
            var result = seed
            result.nodes[0].title = "PR from GitHub"
            return result
        })
        let reply = await store.perform(.addTask(title: "PR", link: "https://github.com/org/repo/pull/12"), using: importer)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(store.workLog?.todos.first?.title, "PR from GitHub")
        XCTAssertEqual(store.sessionWorkIDs, ["github:org/repo#12"])
    }

    @MainActor func testCLIReportsImportFailureAndCancellation() async {
        for canceled in [false, true] {
            let store = store()
            let importer = WorkImporter(fetchLinear: { _ in
                if canceled { throw CancellationError() }
                throw WorkImportError("Linear credentials are missing.")
            }, enrichGitHub: { $0 })
            let reply = await store.perform(.addTask(title: "ENG-1", link: ""), using: importer)
            XCTAssertFalse(reply.ok)
            XCTAssertEqual(reply.message, canceled ? "Import canceled. Saved work is unchanged." : "Linear credentials are missing.")
            XCTAssertTrue(store.graphSessionTasks.isEmpty)
            XCTAssertFalse(store.workImporting)
        }
    }

    @MainActor func testUIAndCLIShareInputAndReviewValidation() async throws {
        let store = store()
        let operation = try store.addWork(" Reference - https://example.com/docs ")
        let message = try await operation.value
        XCTAssertTrue(message.contains("Reference"))
        let duplicate = await store.perform(.addTask(title: "Other title", link: "https://example.com/docs"))
        XCTAssertFalse(duplicate.ok)
        XCTAssertEqual(duplicate.message, "This link is already in the session.")
        store.journal.pendingReviewID = UUID()
        XCTAssertThrowsError(try store.addWork("Next task")) {
            XCTAssertTrue($0.localizedDescription.contains("Review your last session"))
        }
        let refused = await store.perform(.addTask(title: "Next task", link: ""))
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.message.contains("Review your last session"))
    }

    @MainActor func testImportOperationRetainsItsResultAfterStoreClearsTask() async throws {
        let store = store()
        let issue = WorkNode(id: "linear:ENG-1", kind: .linear, title: "Issue")
        let result = WorkImportResult(nodes: [issue], snapshot: WorkImport(id: issue.id, url: "ENG-1", nodeIDs: [issue.id], edges: []))
        let importer = WorkImporter(fetchLinear: { _ in result }, enrichGitHub: { $0 })
        let operation = try store.addWork("ENG-1", using: importer)
        XCTAssertThrowsError(try store.addWork("Another task"))
        let message = try await operation.value
        XCTAssertNil(store.workImportTask)
        let retained = try await operation.value
        XCTAssertEqual(retained, message)
    }

    @MainActor func testImportReportsSessionChangeWithoutAddingToNewSession() async throws {
        let store = store()
        let issue = WorkNode(id: "linear:ENG-1", kind: .linear, title: "Issue")
        let result = WorkImportResult(nodes: [issue], snapshot: WorkImport(id: issue.id, url: "ENG-1", nodeIDs: [issue.id], edges: []))
        let importer = WorkImporter(fetchLinear: { _ in result }, enrichGitHub: { $0 })
        let operation = try store.addWork("ENG-1", using: importer)
        store.start()
        do {
            _ = try await operation.value
            XCTFail("Changing the session must not report a successful addition")
        } catch { XCTAssertTrue(error.localizedDescription.contains("session changed")) }
        XCTAssertTrue(store.sessionWorkIDs.isEmpty)
        XCTAssertTrue(store.workGraph.nodes.contains { $0.id == issue.id })
    }

    @MainActor func testCancelImportOperationLeavesSavedWorkUnchanged() async throws {
        let store = store()
        let importer = WorkImporter(fetchLinear: { _ in
            XCTFail("Canceled work must not fetch")
            throw CancellationError()
        }, enrichGitHub: { $0 })
        let operation = try store.addWork("ENG-1", using: importer)
        store.workImportTask?.cancel()
        do {
            _ = try await operation.value
            XCTFail("Canceled work must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("canceled")) }
        XCTAssertTrue(store.workGraph.nodes.isEmpty)
        XCTAssertFalse(store.workImporting)
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
