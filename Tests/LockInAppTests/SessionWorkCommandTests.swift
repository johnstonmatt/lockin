import XCTest
import LockInCore
@testable import LockIn

final class SessionWorkCommandTests: StoreTestCase {
    @MainActor func testEmptyPlanSelectsNoWork() throws {
        let store = makeStore()
        XCTAssertEqual(store.journal.draft.count, 1, "the planner keeps a blank row")
        XCTAssertEqual(store.sessionWorkIDs, [])
        try store.addWork("Plan the rollout")
        store.removeWorkFromSession(try XCTUnwrap(store.sessionWorkIDs.first))
        XCTAssertEqual(store.sessionWorkIDs, [])
        XCTAssertEqual(store.journal.draft.count, 1)
    }

    @MainActor func testDuplicateNamesRejectWithoutChangingSessionOrDisk() throws {
        let store = makeStore()
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
        XCTAssertEqual(makeStore().workGraph, graph)
    }

    @MainActor func testAddWorkRejectsEquivalentSelectedLinksWithoutMutation() throws {
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
        let added = await store.perform(.addTask(title: "Plan the rollout", link: ""))
        XCTAssertTrue(added.ok, added.message)
        let duplicate = await store.perform(.addTask(title: "PLAN the rollout", link: ""))
        XCTAssertFalse(duplicate.ok)
        XCTAssertEqual(duplicate.message, "This task is already in the session.")
        let linked = await store.perform(.addTask(title: "Reference", link: "https://example.com"))
        XCTAssertTrue(linked.ok)
        XCTAssertEqual(store.sessionGraph.nodes.first { $0.url == "https://example.com" }?.title, "Reference")
        XCTAssertEqual(store.graphSessionTasks.count, 2)
        XCTAssertEqual(makeStore().sessionGraph, store.sessionGraph)
    }

    @MainActor func testCLIImportsLinearDependenciesAndRefreshesSavedWork() async throws {
        let store = makeStore()
        let issue = WorkNode(id: "linear:ENG-1", kind: .linear, title: "Feature", url: "https://linear.app/team/issue/ENG-1")
        let child = WorkNode(id: "github:org/repo#12", kind: .pullRequest, title: "Implementation", url: "https://github.com/org/repo/pull/12")
        let result = WorkImportResult(nodes: [issue, child], snapshot: .fixture(id: issue.id, url: issue.url,
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
        XCTAssertEqual(makeStore().sessionGraph, store.sessionGraph)
    }

    @MainActor func testCLIImportsGitHubIntoActiveSession() async {
        let store = makeStore()
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
            let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
        let issue = WorkNode(id: "linear:ENG-1", kind: .linear, title: "Issue")
        let result = WorkImportResult(nodes: [issue], snapshot: .fixture(id: issue.id, url: "ENG-1", nodeIDs: [issue.id], edges: []))
        let importer = WorkImporter(fetchLinear: { _ in result }, enrichGitHub: { $0 })
        let operation = try store.addWork("ENG-1", using: importer)
        XCTAssertThrowsError(try store.addWork("Another task"))
        let message = try await operation.value
        XCTAssertNil(store.workImportTask, "the store lets go of the task as it finishes")
        XCTAssertEqual(message, "Imported 1 work items.")
        XCTAssertEqual(store.sessionWorkIDs, [issue.id])
    }

    @MainActor func testImportReportsSessionChangeWithoutAddingToNewSession() async throws {
        let store = makeStore()
        let issue = WorkNode(id: "linear:ENG-1", kind: .linear, title: "Issue")
        let result = WorkImportResult(nodes: [issue], snapshot: .fixture(id: issue.id, url: "ENG-1", nodeIDs: [issue.id], edges: []))
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
        let store = makeStore()
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

    @MainActor func testCompletionAndRenameUseActiveSessionWithoutChangingDraftOrSource() throws {
        let store = makeStore()
        let draft = Todo(title: "Next session")
        let remote = WorkNode(id: "pr", kind: .pullRequest, title: "Remote title", status: "Passing")
        let local = Todo(title: "Local task")
        XCTAssertTrue(store.editWorkGraph { $0.nodes = [remote] })
        store.commitJournal {
            $0.setPlan([draft])
            $0.sessions.append(WorkLog(todos: [Todo(work: remote), local], targetSeconds: 60, now: clock.now))
        }
        store.setSessionWorkDone(remote.id, done: true)
        XCTAssertTrue(store.isSessionWorkDone(remote.id))
        XCTAssertFalse(store.isSessionWorkDone("unknown"))
        store.renameSessionWork(remote.id, title: "Session title", link: "")
        XCTAssertEqual(store.graphSessionTasks.first?.title, "Remote title", "imported work keeps its source's title")
        store.renameSessionWork(local.workIdentity, title: "Renamed task", link: "https://example.com/task")
        let renamed = try XCTUnwrap(store.graphSessionTasks.first { $0.id == local.id })
        XCTAssertEqual(renamed.title, "Renamed task")
        XCTAssertEqual(renamed.link, "https://example.com/task")
        XCTAssertEqual(store.workGraph.nodes.first { $0.id == local.workIdentity }?.title, "Renamed task")
        XCTAssertEqual(store.journal.draft, [draft])
        XCTAssertEqual(store.workGraph.nodes.first { $0.id == remote.id }, remote)
    }

    @MainActor func testWorkCantBeAddedWhileTheGraphIsUnwritable() throws {
        let store = makeStore()
        store.workGraphWritable = false
        XCTAssertThrowsError(try store.addWork("Plan the rollout")) {
            XCTAssertEqual($0.localizedDescription, "Work can't be added right now. Try again shortly.")
        }
        XCTAssertTrue(store.workGraph.nodes.isEmpty)
        XCTAssertTrue(store.graphSessionTasks.isEmpty)
    }

    @MainActor func testRenamingLocalWorkRejectsAnInvalidLink() throws {
        let store = makeStore()
        try store.addWork("Plan the rollout")
        let id = try XCTUnwrap(store.sessionWorkIDs.first)
        for (title, link) in [("Renamed", "notaurl"), ("Renamed", "ftp://example.com/file"), ("  ", "")] {
            store.renameSessionWork(id, title: title, link: link)
            XCTAssertEqual(store.graphSessionTasks.map(\.title), ["Plan the rollout"], "\(title) \(link)")
            XCTAssertEqual(store.graphSessionTasks.first?.link, "")
        }
        XCTAssertEqual(store.workGraph.nodes.first { $0.id == id }?.title, "Plan the rollout")
    }

    @MainActor func testSyncLocalWorkUpdatesLocalNodesFromTasks() throws {
        let store = makeStore()
        let remote = WorkNode(id: "pr", kind: .pullRequest, title: "Remote title", status: "Open")
        XCTAssertTrue(store.editWorkGraph { $0.nodes = [remote] })
        try store.addWork("Plan the rollout")
        let id = try XCTUnwrap(store.sessionWorkIDs.first)
        store.journal.draft = store.journal.draft.map { task in
            var task = task
            task.title = "Roll out"; task.link = "https://example.com/rollout"; task.completed = true
            return task
        } + [Todo(work: remote)]
        store.syncLocalWork()
        let local = try XCTUnwrap(store.workGraph.nodes.first { $0.id == id })
        XCTAssertEqual(local.title, "Roll out")
        XCTAssertEqual(local.url, "https://example.com/rollout")
        XCTAssertTrue(local.resolved)
        XCTAssertEqual(local.status, "Done")
        XCTAssertEqual(store.workGraph.nodes.first { $0.id == remote.id }, remote, "imported work keeps its source's details")
        XCTAssertEqual(try WorkGraphStorage.load(from: directory), store.workGraph, "the update is saved")
    }
}
