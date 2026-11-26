import XCTest
import LockInCore
@testable import LockIn

final class WorkListLayoutTests: XCTestCase {
    private func graph() -> WorkGraph {
        var graph = WorkGraph()
        let nodes = [
            WorkNode(id: "root", kind: .linear, title: "Root", label: "ENG-1", context: true),
            WorkNode(id: "child", kind: .linear, title: "Child", label: "ENG-2"),
            WorkNode(id: "pr", kind: .pullRequest, title: "Implementation", label: "app#1"),
            WorkNode(id: "base", kind: .pullRequest, title: "Prerequisite", label: "app#2", context: true)
        ]
        graph.merge(WorkImportResult(nodes: nodes, snapshot: WorkImport(id: "root", url: "", nodeIDs: nodes.map(\.id), edges: [
            WorkEdge(from: "root", to: "child", kind: .contains, source: .linear),
            WorkEdge(from: "child", to: "pr", kind: .implements, source: .linear),
            WorkEdge(from: "base", to: "pr", kind: .depends, source: .stack)
        ])))
        return graph
    }

    func testNestedIssuesAndPRsStayTogetherButDependenciesAreNotParents() {
        let rows = WorkListLayout(graph: graph(), filter: .all, collapsed: []).rows
        let rootIndex = rows.firstIndex { $0.id == "root" }!
        XCTAssertEqual(Array(rows[rootIndex...].prefix(3)).map(\.id), ["root", "child", "pr"])
        XCTAssertEqual(rows.first { $0.id == "root" }?.depth, 0)
        XCTAssertEqual(rows.first { $0.id == "child" }?.depth, 1)
        XCTAssertEqual(rows.first { $0.id == "pr" }?.depth, 2)
        XCTAssertEqual(rows.first { $0.id == "base" }?.depth, 0)
        XCTAssertEqual(rows.first { $0.id == "root" }?.node.context, true)
    }

    func testCollapseCountsDescendantsAndMatchesGraphVisibility() {
        for collapsed: Set<String> in [["root"], ["child"], ["root", "child"], []] {
            let list = WorkListLayout(graph: graph(), filter: .all, collapsed: collapsed)
            let canvas = WorkGraphLayout(graph: graph(), filter: .all, collapsed: collapsed)
            XCTAssertEqual(Set(list.rows.map(\.id)), Set(canvas.positions.keys))
            XCTAssertEqual(list.rows.first { $0.id == "root" }?.descendantCount, 2)
        }
    }

    func testFiltersKeepIssueTreeAndFlattenPRsWithBreadcrumbs() {
        let issues = WorkListLayout(graph: graph(), filter: .issues, collapsed: []).rows
        XCTAssertEqual(issues.map(\.id), ["root", "child"])
        XCTAssertEqual(issues.map(\.depth), [0, 1])
        XCTAssertEqual(issues[0].descendantCount, 1)
        let prs = WorkListLayout(graph: graph(), filter: .prs, collapsed: ["root", "child"]).rows
        XCTAssertEqual(Set(prs.map(\.id)), ["pr", "base"])
        XCTAssertTrue(prs.allSatisfy { $0.depth == 0 && $0.descendantCount == 0 })
        XCTAssertEqual(prs.first { $0.id == "pr" }?.breadcrumb, "ENG-1 / ENG-2")
        XCTAssertNil(prs.first { $0.id == "base" }?.breadcrumb)
    }

    func testSharedPRAndCyclicMembershipHaveStableSingleRows() {
        var graph = graph()
        graph.imports[0].edges += [
            WorkEdge(from: "root", to: "pr", kind: .implements, source: .linear),
            WorkEdge(from: "child", to: "root", kind: .contains, source: .linear)
        ]
        let list = WorkListLayout(graph: graph, filter: .all, collapsed: []).rows
        XCTAssertEqual(list.count, graph.nodes.count)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        graph.imports[0].edges.reverse()
        XCTAssertEqual(WorkListLayout(graph: graph, filter: .all, collapsed: []).rows.map(\.id), list.map(\.id))
    }
}
