import XCTest
import LockInCore
@testable import LockIn

final class WorkRoutingRegressionTests: XCTestCase {
    func testSiblingRegionsDoNotRouteAcrossEachOthersHeaders() {
        let nodes: [WorkNode] = [
            WorkNode(id: "n00", kind: .pullRequest, title: "n00"),
            WorkNode(id: "n01", kind: .pullRequest, title: "n01"),
            WorkNode(id: "n02", kind: .pullRequest, title: "n02"),
            WorkNode(id: "n03", kind: .pullRequest, title: "n03"),
            WorkNode(id: "n04", kind: .pullRequest, title: "n04"),
            WorkNode(id: "n05", kind: .pullRequest, title: "n05"),
            WorkNode(id: "n06", kind: .pullRequest, title: "n06"),
            WorkNode(id: "n07", kind: .pullRequest, title: "n07"),
            WorkNode(id: "n08", kind: .pullRequest, title: "n08"),
            WorkNode(id: "n09", kind: .pullRequest, title: "n09"),
            WorkNode(id: "n10", kind: .pullRequest, title: "n10"),
            WorkNode(id: "n11", kind: .pullRequest, title: "n11"),
            WorkNode(id: "n12", kind: .linear, title: "n12"),
            WorkNode(id: "n13", kind: .linear, title: "n13"),
            WorkNode(id: "n14", kind: .linear, title: "n14"),
            WorkNode(id: "n15", kind: .linear, title: "n15"),
            WorkNode(id: "n16", kind: .linear, title: "n16"),
            WorkNode(id: "n17", kind: .linear, title: "n17"),
            WorkNode(id: "n18", kind: .linear, title: "n18"),
            WorkNode(id: "n19", kind: .linear, title: "n19"),
            WorkNode(id: "n20", kind: .linear, title: "n20"),
            WorkNode(id: "n21", kind: .linear, title: "n21"),
            WorkNode(id: "n22", kind: .linear, title: "n22"),
            WorkNode(id: "n23", kind: .linear, title: "n23"),
            WorkNode(id: "n24", kind: .linear, title: "n24"),
            WorkNode(id: "n25", kind: .linear, title: "n25"),
            WorkNode(id: "n26", kind: .linear, title: "n26"),
        ]
        let edges: [WorkEdge] = [
            WorkEdge(from: "n02", to: "n03", kind: .depends, source: .branch),
            WorkEdge(from: "n12", to: "n02", kind: .implements, source: .linear),
            WorkEdge(from: "n12", to: "n03", kind: .implements, source: .linear),
            WorkEdge(from: "n12", to: "n15", kind: .contains, source: .linear),
            WorkEdge(from: "n12", to: "n16", kind: .contains, source: .linear),
            WorkEdge(from: "n12", to: "n25", kind: .contains, source: .linear),
            WorkEdge(from: "n13", to: "n02", kind: .implements, source: .linear),
            WorkEdge(from: "n13", to: "n03", kind: .implements, source: .linear),
            WorkEdge(from: "n14", to: "n05", kind: .implements, source: .linear),
            WorkEdge(from: "n14", to: "n06", kind: .implements, source: .linear),
            WorkEdge(from: "n14", to: "n20", kind: .depends, source: .linear),
            WorkEdge(from: "n18", to: "n04", kind: .implements, source: .linear),
            WorkEdge(from: "n18", to: "n08", kind: .implements, source: .linear),
            WorkEdge(from: "n18", to: "n13", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n14", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n17", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n19", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n20", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n21", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n22", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n23", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n24", kind: .contains, source: .linear),
            WorkEdge(from: "n18", to: "n26", kind: .contains, source: .linear),
            WorkEdge(from: "n19", to: "n00", kind: .implements, source: .linear),
            WorkEdge(from: "n19", to: "n04", kind: .implements, source: .linear),
            WorkEdge(from: "n19", to: "n22", kind: .depends, source: .linear),
            WorkEdge(from: "n20", to: "n11", kind: .implements, source: .linear),
            WorkEdge(from: "n20", to: "n19", kind: .depends, source: .linear),
            WorkEdge(from: "n20", to: "n24", kind: .depends, source: .linear),
            WorkEdge(from: "n20", to: "n26", kind: .depends, source: .linear),
            WorkEdge(from: "n21", to: "n08", kind: .implements, source: .linear),
            WorkEdge(from: "n21", to: "n09", kind: .implements, source: .linear),
            WorkEdge(from: "n21", to: "n20", kind: .depends, source: .linear),
            WorkEdge(from: "n22", to: "n07", kind: .implements, source: .linear),
            WorkEdge(from: "n25", to: "n15", kind: .depends, source: .linear),
            WorkEdge(from: "n25", to: "n16", kind: .depends, source: .linear),
            WorkEdge(from: "n26", to: "n01", kind: .implements, source: .linear),
            WorkEdge(from: "n26", to: "n10", kind: .implements, source: .linear),
            WorkEdge(from: "n26", to: "n22", kind: .depends, source: .linear),
        ]
        var graph = WorkGraph()
        graph.merge(WorkImportResult(nodes: nodes, snapshot: WorkImport(id: "fixture", url: "", nodeIDs: nodes.map(\.id), edges: edges)))
        let layout = WorkGraphLayout(graph: graph, filter: .all, collapsed: [])
        let routes = WorkEdgeRoute.plan(edges: graph.sequencing.edges, layout: layout)
        XCTAssertEqual(routes.count, graph.sequencing.edges.count)
        XCTAssertEqual(WorkEdgeRoute.obstructionCost(routes: routes, edges: graph.sequencing.edges, layout: layout), 0)
        XCTAssertTrue(routes.values.allSatisfy { $0.points.count <= 4 })
    }
}
