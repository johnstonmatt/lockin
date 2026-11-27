import XCTest
import LockInCore
@testable import LockIn

final class WorkGraphIntegrationTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    @MainActor private func store() -> Store { Store(directory: directory, runTimer: false, enforceBlocking: false, channel: nil) }

    private func imported() -> WorkImportResult {
        let issue = WorkNode(id: "linear:root", kind: .linear, title: "Build a feature")
        let context = WorkNode(id: "github:app#1", kind: .pullRequest, title: "Prerequisite", context: true)
        let pr = WorkNode(id: "github:app#2", kind: .pullRequest, title: "Feature")
        let merged = WorkNode(id: "github:app#3", kind: .pullRequest, title: "Done", status: "Merged", resolved: true)
        let nodes = [issue, context, pr, merged]
        return WorkImportResult(nodes: nodes, snapshot: WorkImport(id: issue.id, url: "https://linear.app/a/issue/A-1",
            nodeIDs: nodes.map(\.id), edges: [
                WorkEdge(from: issue.id, to: pr.id, kind: .implements, source: .linear),
                WorkEdge(from: context.id, to: pr.id, kind: .depends, source: .stack),
                WorkEdge(from: issue.id, to: merged.id, kind: .implements, source: .linear)
            ], refreshedAt: Date(timeIntervalSince1970: 1700000000)))
    }
    @MainActor func testAddingSavedWorkRefreshesItsDependencies() async throws {
        let store = store()
        var saved = imported()
        saved.nodes[0].url = saved.snapshot.url
        try store.applyWorkImport(saved, addToSession: false, targetSession: nil)
        var updated = saved
        updated.nodes[2].title = "Updated feature"
        let dependency = WorkNode(id: "github:app#4", kind: .pullRequest, title: "New dependency")
        updated.nodes.append(dependency)
        updated.snapshot.nodeIDs.append(dependency.id)
        updated.snapshot.edges.append(WorkEdge(from: saved.snapshot.id, to: dependency.id, kind: .implements, source: .linear))
        let result = updated
        let importer = WorkImporter(fetchLinear: { _ in result }, enrichGitHub: { $0 })

        let operation = try store.addWork(saved.snapshot.url, using: importer)
        _ = try await operation.value

        XCTAssertEqual(store.sessionWorkIDs, [saved.snapshot.id])
        XCTAssertEqual(store.sessionGraph.nodes.first { $0.id == "github:app#2" }?.title, "Updated feature")
        XCTAssertTrue(store.sessionGraph.nodes.contains { $0.id == dependency.id })
        XCTAssertEqual(self.store().workGraph, store.workGraph)
    }

    @MainActor func testDescendantsRejectAsDuplicatesAndCannotBeEdited() throws {
        let store = store()
        var result = imported()
        result.nodes[2].url = "https://github.com/acme/app/pull/2"
        try store.applyWorkImport(result, addToSession: true, targetSession: nil)
        for input in [result.nodes[2].url, result.nodes[2].title] {
            XCTAssertThrowsError(try store.addWork(input)) {
                XCTAssertTrue($0.localizedDescription.contains("Already included through"))
            }
        }
        XCTAssertFalse(store.selectWorkForSession(result.nodes[2]))
        store.setSessionWorkDone(result.nodes[2].id, done: true)
        store.renameSessionWork(result.nodes[2].id, title: "Changed", link: "")
        XCTAssertEqual(store.graphSessionTasks.count, 1)
        XCTAssertFalse(store.graphSessionTasks[0].completed)
        XCTAssertEqual(store.workGraph.nodes.first { $0.id == result.nodes[2].id }?.title, "Feature")
        store.removeWorkFromSession(result.snapshot.id)
        XCTAssertTrue(store.sessionGraph.nodes.isEmpty)
    }

    @MainActor func testSelectingParentAbsorbsSelectedChildrenAndRestartKeepsOnlyRoot() throws {
        let store = store()
        let result = imported()
        try store.applyWorkImport(result, addToSession: false, targetSession: nil)
        XCTAssertTrue(store.selectWorkForSession(result.nodes[2]))
        XCTAssertTrue(store.selectWorkForSession(result.nodes[0]))
        XCTAssertEqual(store.sessionWorkIDs, [result.snapshot.id])
        XCTAssertEqual(self.store().sessionWorkIDs, [result.snapshot.id])
        XCTAssertEqual(Set(store.sessionGraph.nodes.map(\.id)), Set(result.nodes.map(\.id)))
    }

    @MainActor func testUnknownImportedChildIsRejectedWhenMembershipRevealsSelectedParent() throws {
        let store = store()
        let result = imported()
        XCTAssertTrue(store.selectWorkForSession(result.nodes[0]))
        var childImport = result
        childImport.snapshot.id = result.nodes[2].id
        XCTAssertThrowsError(try store.applyWorkImport(childImport, addToSession: true, targetSession: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("Already included through"))
        }
        XCTAssertEqual(store.sessionWorkIDs, [result.nodes[0].id])
    }
    @MainActor func testImportSelectsSessionWorkButNotExternalPrerequisitesAndPersists() throws {
        let store = store()
        try store.applyWorkImport(imported(), addToSession: true, targetSession: nil)
        XCTAssertEqual(store.sessionWorkIDs, ["linear:root"])
        XCTAssertTrue(store.sessionGraph.nodes.contains { $0.id == "github:app#1" })
        XCTAssertFalse(store.sessionWorkIDs.contains("github:app#1"))
        let restored = self.store()
        XCTAssertEqual(restored.workGraph, store.workGraph)
        XCTAssertEqual(restored.sessionWorkIDs, store.sessionWorkIDs)
        try restored.applyWorkImport(imported(), addToSession: true, targetSession: nil)
        XCTAssertEqual(restored.graphSessionTasks.count, 1)
    }
    @MainActor func testRefreshDoesNotReAddRemovedTasksOrChangeLocalCompletion() throws {
        let store = store()
        try store.applyWorkImport(imported(), addToSession: true, targetSession: nil)
        store.removeWorkFromSession("github:app#2")
        store.setSessionWorkDone("linear:root", done: true)
        try store.applyWorkImport(imported(), addToSession: false, targetSession: nil)
        XCTAssertEqual(store.sessionWorkIDs, ["linear:root"])
        XCTAssertTrue(store.graphSessionTasks[0].completed)
        XCTAssertFalse(store.workGraph.nodes.first { $0.id == "linear:root" }!.resolved)
    }
    @MainActor func testImportFinishingAfterSessionChangedDoesNotSelectWork() throws {
        let store = store()
        XCTAssertThrowsError(try store.applyWorkImport(imported(), addToSession: true, targetSession: UUID())) {
            XCTAssertTrue($0.localizedDescription.contains("session changed"))
        }
        XCTAssertTrue(store.graphSessionTasks.isEmpty)
        XCTAssertEqual(store.workGraph.nodes.count, 4)
    }
    @MainActor func testLegacyTasksKeepGraphIdentityAndLocalEdits() throws {
        let store = store()
        let todo = Todo(title: "Old task")
        store.commitJournal { $0.setPlan([todo]) }
        XCTAssertEqual(store.sessionGraph.nodes[0].id, "local:\(todo.id.uuidString)")
        store.renameSessionWork("local:\(todo.id.uuidString)", title: "Renamed", link: "")
        let restored = self.store()
        XCTAssertEqual(restored.sessionGraph.nodes[0].title, "Renamed")
        XCTAssertEqual(restored.workGraph.nodes[0].title, "Renamed")
    }
    @MainActor func testCorruptGraphIsProtectedWhileSessionsStillWork() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = Data("broken".utf8)
        try content.write(to: WorkGraphStorage.file(in: directory))
        let store = store()
        XCTAssertFalse(store.editWorkGraph { $0.nodes.removeAll() })
        store.commitJournal { $0.setPlan([Todo(title: "Session task")]) }
        XCTAssertEqual(store.graphSessionTasks.count, 1)
        XCTAssertEqual(try Data(contentsOf: WorkGraphStorage.file(in: directory)), content)
    }
    func testRegionsNestSubIssuesAndCollapseAllDescendants() throws {
        var graph = WorkGraph()
        let root = WorkNode(id: "root", kind: .linear, title: "Root")
        let child = WorkNode(id: "child", kind: .linear, title: "Child")
        let pr = WorkNode(id: "pr", kind: .pullRequest, title: "PR")
        graph.merge(WorkImportResult(nodes: [root, child, pr], snapshot: WorkImport(id: root.id, url: "", nodeIDs: ["root", "child", "pr"], edges: [
            WorkEdge(from: "root", to: "child", kind: .contains, source: .linear),
            WorkEdge(from: "child", to: "pr", kind: .implements, source: .linear)
        ])))
        let layout = WorkGraphLayout(graph: graph, filter: .all, collapsed: [])
        let outer = try XCTUnwrap(layout.groups.first { $0.id == "root" })
        let inner = try XCTUnwrap(layout.groups.first { $0.id == "child" })
        XCTAssertTrue(outer.rect.contains(inner.rect))
        XCTAssertTrue(inner.rect.contains(try XCTUnwrap(layout.frames["pr"])))
        XCTAssertEqual(layout.frames["child"]?.height, WorkGraphLayout.regionHeaderHeight)
        let folded = WorkGraphLayout(graph: graph, filter: .all, collapsed: ["root"])
        XCTAssertNil(folded.frames["child"])
        XCTAssertNil(folded.frames["pr"])
        XCTAssertEqual(folded.representatives["pr"], "root")
        XCTAssertEqual(folded.groups.first?.memberIDs, ["child", "pr"])
        let prs = WorkGraphLayout(graph: graph, filter: .prs, collapsed: ["root"])
        XCTAssertNotNil(prs.frames["pr"])
        XCTAssertTrue(prs.groups.isEmpty)
    }

    func testSharedPRHasOneRegionAndMalformedHierarchyDoesNotLoop() {
        var graph = WorkGraph()
        let nodes = [
            WorkNode(id: "a", kind: .linear, title: "A"),
            WorkNode(id: "b", kind: .linear, title: "B"),
            WorkNode(id: "pr", kind: .pullRequest, title: "PR")
        ]
        graph.merge(WorkImportResult(nodes: nodes, snapshot: WorkImport(id: "a", url: "", nodeIDs: nodes.map(\.id), edges: [
            WorkEdge(from: "a", to: "b", kind: .contains, source: .linear),
            WorkEdge(from: "b", to: "a", kind: .contains, source: .linear),
            WorkEdge(from: "a", to: "pr", kind: .implements, source: .linear),
            WorkEdge(from: "b", to: "pr", kind: .implements, source: .linear)
        ])))
        let layout = WorkGraphLayout(graph: graph, filter: .all, collapsed: [])
        XCTAssertEqual(layout.positions.count, 3)
        XCTAssertNotNil(layout.positions["pr"])
        XCTAssertTrue(layout.size.width.isFinite)
        XCTAssertTrue(layout.size.height.isFinite)
    }

    func testLayoutKeepsCrossIssuePRStackOrderedAndCollapseDoesNotLoseDependency() {
        let result = imported()
        var graph = WorkGraph(); graph.merge(result)
        let layout = WorkGraphLayout(graph: graph, filter: .all, collapsed: [])
        XCTAssertLessThan(layout.positions["github:app#1"]!.y, layout.positions["github:app#2"]!.y)
        let collapsed = WorkGraphLayout(graph: graph, filter: .all, collapsed: ["linear:root"])
        XCTAssertNil(collapsed.positions["github:app#2"])
        XCTAssertEqual(collapsed.representatives["github:app#2"], "linear:root")
        XCTAssertNotNil(collapsed.positions["github:app#1"])
    }
}
