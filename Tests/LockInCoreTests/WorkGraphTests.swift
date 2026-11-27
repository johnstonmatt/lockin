import XCTest
@testable import LockInCore
import LockInTestSupport

final class WorkGraphTests: XCTestCase {
    func testSessionNormalizationKeepsRootsInPlanAndActiveSession() {
        var graph = WorkGraph()
        graph.merge(result([node("root"), node("child"), node("pr")], [
            WorkEdge(from: "root", to: "child", kind: .contains, source: .linear),
            WorkEdge(from: "child", to: "pr", kind: .implements, source: .linear)
        ]))
        let tasks = ["root", "child", "pr"].map { id in
            var task = Todo(title: id); task.workNodeID = id; return task
        }
        var journal = JournalState()
        journal.setPlan(tasks)
        journal.sessions.append(WorkLog(todos: tasks, targetSeconds: 60, now: Date()))
        journal.normalizeWorkEntries(using: graph)
        XCTAssertEqual(journal.draft.map(\.workIdentity), ["root"])
        XCTAssertEqual(journal.openSession?.todos.map(\.workIdentity), ["root"])
        XCTAssertEqual(graph.topLevelIDs(["child", "pr"]), ["child"])
    }

    func testStoredOverridesCannotChangeSourceSequencing() throws {
        var graph = WorkGraph()
        let edge = WorkEdge(from: "a", to: "b", kind: .depends, source: .stack)
        graph.merge(result([node("a"), node("b")], [edge]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: FileFormat.encoder.encode(graph)) as? [String: Any])
        object["excluded_dependencies"] = ["a|b"]
        object["local_edges"] = [["from": "b", "to": "a", "kind": "depends", "source": "local"]]
        let restored = try FileFormat.decoder.decode(WorkGraph.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.sequencing.edges, [edge])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: FileFormat.encoder.encode(restored)) as? [String: Any])
        XCTAssertNil(saved["local_edges"])
        XCTAssertNil(saved["excluded_dependencies"])
    }

    private func node(_ id: String, kind: WorkNode.Kind = .pullRequest, resolved: Bool = false) -> WorkNode {
        WorkNode(id: id, kind: kind, title: id, resolved: resolved)
    }
    private func result(_ nodes: [WorkNode], _ edges: [WorkEdge]) -> WorkImportResult {
        WorkImportResult(nodes: nodes, snapshot: .fixture(id: "root", url: "https://linear.app/a/issue/A-1",
            nodeIDs: nodes.map(\.id), edges: edges))
    }
    func testImportRefreshSurvivesDiskRoundTrip() throws {
        let edge = WorkEdge(from: "a", to: "b", kind: .depends, source: .stack)
        var graph = WorkGraph()
        let imported = result([node("a"), node("b")], [edge])
        graph.merge(imported)
        graph.merge(imported)
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.sequencing.edges, [edge])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Storage.saveWorkGraph(graph, in: directory)
        var restored = try XCTUnwrap(Storage.loadWorkGraph(from: directory))
        XCTAssertEqual(restored, graph)
        XCTAssertEqual(restored.sequencing.edges, [edge])
        restored.merge(result(imported.nodes, []))
        XCTAssertTrue(restored.sequencing.edges.isEmpty, "removed source relations must disappear on refresh")
    }
    func testMembershipDoesNotBlockAndUnmergedClosedPRDoes() {
        var graph = WorkGraph()
        var closed = node("closed"); closed.status = "Closed"; closed.attention = true
        graph.merge(result([node("issue", kind: .linear), closed, node("merged", resolved: true), node("pr")], [
            WorkEdge(from: "issue", to: "pr", kind: .implements, source: .linear),
            WorkEdge(from: "merged", to: "pr", kind: .depends, source: .stack),
            WorkEdge(from: "closed", to: "pr", kind: .depends, source: .branch)
        ]))
        XCTAssertEqual(graph.blocking(graph.sequencing.edges).filter { $0.to == "pr" }.map(\.from), ["closed"])
    }
    func testFocusedGraphIncludesPrerequisitesAndTheirIssuesButNotUnrelatedWork() {
        var graph = WorkGraph()
        graph.merge(result(["issue", "other", "a", "b", "unrelated"].map { node($0) }, [
            WorkEdge(from: "issue", to: "b", kind: .implements, source: .linear),
            WorkEdge(from: "other", to: "a", kind: .implements, source: .linear),
            WorkEdge(from: "a", to: "b", kind: .depends, source: .stack)
        ]))
        let focused = graph.focused(on: ["b"])
        XCTAssertEqual(Set(focused.nodes.map(\.id)), ["issue", "other", "a", "b"])
        XCTAssertEqual(focused.blocking(focused.sequencing.edges).filter { $0.to == "b" }.map(\.from), ["a"])
    }
    func testConflictingEvidenceKeepsStackOverBranch() {
        var graph = WorkGraph()
        graph.merge(result([node("a"), node("b")], [
            WorkEdge(from: "a", to: "b", kind: .depends, source: .stack),
            WorkEdge(from: "b", to: "a", kind: .depends, source: .branch)
        ]))
        XCTAssertEqual(graph.sequencing.edges.map(\.source), [.stack])
        XCTAssertEqual(graph.sequencing.conflicts.map(\.source), [.branch])
    }
    func testGraphFileMatchesSchema() throws {
        var graph = WorkGraph()
        graph.merge(result([node("a"), node("b")], [
            WorkEdge(from: "a", to: "b", kind: .depends, source: .stack)
        ]))
        graph.nodes[0].readiness = PullRequestReadiness(checks: .success, reviewDecision: "APPROVED", mergeState: "CLEAN", isDraft: false, headOID: "abc")
        let validator = SchemaValidator()
        XCTAssertEqual(try validator.errors(FileFormat.encoder.encode(graph), against: "work-graph-v1.schema.json"), [])
        XCTAssertEqual(validator.unseen, [])
    }
    func testCorruptOrFutureFileIsNotOverwrittenByLoading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = Storage.workGraphFile(in: directory)
        for content in [Data("bad json".utf8), Data(#"{"schema_version":999}"#.utf8)] {
            try content.write(to: file)
            XCTAssertThrowsError(try Storage.loadWorkGraph(from: directory))
            XCTAssertEqual(try Data(contentsOf: file), content)
        }
    }
    func testDuplicateNodesAreReportedByName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var graph = WorkGraph()
        graph.nodes = [node("same"), node("same")]
        try Storage.saveWorkGraph(graph, in: directory)
        XCTAssertThrowsError(try Storage.loadWorkGraph(from: directory)) {
            XCTAssertTrue($0.localizedDescription.hasSuffix("It lists “same” more than once."), $0.localizedDescription)
        }
    }
    func testLegacyTaskRolloverKeepsPersistentIdentityAcrossSessions() {
        var original = Todo(title: "Local task"); original.rollForward = true
        let first = WorkLog(todos: [original], targetSeconds: 60, now: Date())
        var next = first.rolledTodos[0]; next.rollForward = true
        let second = WorkLog(todos: [next], targetSeconds: 60, now: Date())
        XCTAssertEqual(next.workNodeID, "local:\(original.id.uuidString)")
        XCTAssertEqual(second.rolledTodos[0].workNodeID, next.workNodeID)
        XCTAssertEqual(WorkGraph.migrating([next]).nodes[0].id, next.workNodeID)
    }

    func testSelectedIssueExpandsNestedWorkButOutsideBlockersDoNotExpandTheirSiblings() {
        var graph = WorkGraph()
        graph.merge(result(["root", "child", "grandchild", "outside", "blocker", "sibling"].map { node($0) }, [
            WorkEdge(from: "root", to: "child", kind: .contains, source: .linear),
            WorkEdge(from: "child", to: "grandchild", kind: .implements, source: .linear),
            WorkEdge(from: "outside", to: "blocker", kind: .implements, source: .linear),
            WorkEdge(from: "outside", to: "sibling", kind: .implements, source: .linear),
            WorkEdge(from: "blocker", to: "grandchild", kind: .depends, source: .stack)
        ]))
        XCTAssertEqual(Set(graph.focused(on: ["root"]).nodes.map(\.id)), ["root", "child", "grandchild", "outside", "blocker"])
    }

    func testSessionReferenceSurvivesSerializationAndRollover() throws {
        var task = Todo(title: "PR"); task.workNodeID = "github:acme/app#1"; task.rollForward = true
        let log = WorkLog(todos: [task], targetSeconds: 60, now: Date())
        let record = try FileFormat.encoder.encode(SessionFile(log, checkpoint: nil))
        let restored = try FileFormat.decoder.decode(SessionFile.self, from: record).log
        XCTAssertEqual(restored.todos[0].workNodeID, task.workNodeID)
        XCTAssertEqual(restored.rolledTodos[0].workNodeID, task.workNodeID)
        XCTAssertNotEqual(restored.rolledTodos[0].id, task.id)
    }
}
