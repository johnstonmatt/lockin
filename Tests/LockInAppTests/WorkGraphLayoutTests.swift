import XCTest
import LockInCore
@testable import LockIn
import LockInTestSupport

final class WorkGraphLayoutTests: XCTestCase {
    static func fixture() -> WorkImportResult {
        let nodes = [
            WorkNode(id: "root", kind: .linear, title: "Ship session sync", label: "ENG-200"),
            WorkNode(id: "backend", kind: .linear, title: "Sync service", label: "ENG-201"),
            WorkNode(id: "client", kind: .linear, title: "Desktop sync", label: "ENG-202"),
            WorkNode(id: "a", kind: .pullRequest, title: "Define the sync protocol", label: "app#101"),
            WorkNode(id: "b", kind: .pullRequest, title: "Implement upload endpoint", label: "app#102"),
            WorkNode(id: "c", kind: .pullRequest, title: "Implement download endpoint", label: "app#103"),
            WorkNode(id: "d", kind: .pullRequest, title: "Connect the desktop client", label: "app#104"),
            WorkNode(id: "e", kind: .pullRequest, title: "Handle offline changes", label: "app#105"),
            WorkNode(id: "f", kind: .pullRequest, title: "Enable sync in settings", label: "app#106")
        ]
        let edges = [
            WorkEdge(from: "root", to: "backend", kind: .contains, source: .linear),
            WorkEdge(from: "root", to: "client", kind: .contains, source: .linear)
        ] + ["a", "b", "c"].map { WorkEdge(from: "backend", to: $0, kind: .implements, source: .linear) }
          + ["d", "e", "f"].map { WorkEdge(from: "client", to: $0, kind: .implements, source: .linear) }
          + [("a", "b"), ("a", "c"), ("b", "d"), ("c", "e"), ("d", "f"), ("e", "f")].map {
              WorkEdge(from: $0.0, to: $0.1, kind: .depends, source: .stack)
          }
        return WorkImportResult(nodes: nodes, snapshot: .fixture(id: "root", nodeIDs: nodes.map(\.id), edges: edges))
    }

    private func graph(_ ids: [String], edges: [(String, String)]) -> WorkGraph {
        var graph = WorkGraph()
        let nodes = ids.map { WorkNode(id: $0, kind: .pullRequest, title: $0) }
        graph.merge(WorkImportResult(nodes: nodes, snapshot: .fixture(id: "test", nodeIDs: ids,
            edges: edges.map { WorkEdge(from: $0.0, to: $0.1, kind: .depends, source: .stack) })))
        return graph
    }

    func testStackUsesOneColumnAndBranchesRejoinWithoutOverlap() throws {
        let chain = WorkGraphLayout(graph: graph(["a", "b", "c", "d"], edges: [("a", "b"), ("b", "c"), ("c", "d")]), filter: .prs, collapsed: [])
        XCTAssertEqual(Set(chain.positions.values.map(\.x)).count, 1)
        XCTAssertLessThan(chain.size.width, 500)
        let branch = WorkGraphLayout(graph: graph(["a", "b", "c", "d"], edges: [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d")]), filter: .prs, collapsed: [])
        XCTAssertEqual(branch.frames["b"]?.minY, branch.frames["c"]?.minY)
        XCTAssertFalse(branch.frames["b"]!.intersects(branch.frames["c"]!))
        XCTAssertGreaterThan(branch.frames["d"]!.minY, branch.frames["b"]!.maxY)
    }

    func testNeighborsAlignDespiteReverseIdentifierOrder() {
        let value = graph(["a", "b", "y", "z", "end"], edges: [("a", "z"), ("b", "y"), ("y", "end"), ("z", "end")])
        let layout = WorkGraphLayout(graph: value, filter: .prs, collapsed: [])
        XCTAssertEqual(layout.positions["a"]?.x, layout.positions["z"]?.x)
        XCTAssertEqual(layout.positions["b"]?.x, layout.positions["y"]?.x)
    }

    func testDisconnectedWorkWrapsInsteadOfMakingAWideStrip() {
        let layout = WorkGraphLayout(graph: graph((1...12).map(String.init), edges: []), filter: .prs, collapsed: [])
        XCTAssertLessThan(layout.size.width, 1400)
        XCTAssertGreaterThan(Set(layout.frames.values.map(\.minY)).count, 1)
    }

    func testNestedBranchesStayContainedOrderedAndDeterministic() {
        var graph = WorkGraph(merging: Self.fixture())
        let layout = WorkGraphLayout(graph: graph, filter: .all, collapsed: [])
        for group in layout.groups {
            for id in group.memberIDs {
                if let child = layout.frames[id] { XCTAssertTrue(group.rect.contains(child), "\(group.id) must contain \(id)") }
            }
        }
        let rects = Array(layout.frames.values)
        for i in rects.indices {
            for j in rects.indices where j > i { XCTAssertFalse(rects[i].intersects(rects[j])) }
        }
        for edge in graph.sequencing.edges {
            XCTAssertLessThan(layout.frames[edge.from]!.maxY, layout.frames[edge.to]!.minY)
        }
        graph.nodes.reverse(); graph.imports[0].edges.reverse()
        XCTAssertEqual(WorkGraphLayout(graph: graph, filter: .all, collapsed: []).frames, layout.frames)
    }

    func testLongArrowRoutesAroundAnInterveningCard() {
        let source = CGRect(x: 20, y: 20, width: 230, height: 120)
        let obstacle = CGRect(x: 20, y: 180, width: 230, height: 120)
        let target = CGRect(x: 20, y: 340, width: 230, height: 120)
        let route = WorkEdgeRoute(source: source, target: target, obstacles: [obstacle])
        XCTAssertLessThanOrEqual(route.points.count, 4, "A connector has at most two bends")
        XCTAssertEqual(route.points.first?.y, source.midY)
        XCTAssertEqual(route.points.last?.y, target.midY)
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertFalse(WorkEdgeRoute.intersects(a, b, obstacle))
            XCTAssertFalse(WorkEdgeRoute.intersects(a, b, source))
            XCTAssertFalse(WorkEdgeRoute.intersects(a, b, target))
        }
    }
    func testNeighboringTargetsDoNotShareAnArrowJunction() {
        let source = CGRect(x: 500, y: 20, width: 270, height: 92)
        let left = CGRect(x: 20, y: 350, width: 270, height: 92)
        let right = CGRect(x: 322, y: 350, width: 500, height: 92)
        let blocker = CGRect(x: 500, y: 140, width: 270, height: 160)
        let first = WorkEdgeRoute(source: source, target: left, obstacles: [right, blocker])
        let second = WorkEdgeRoute(source: source, target: right, obstacles: [left, blocker], occupied: [first.points])
        XCTAssertLessThanOrEqual(first.points.count, 4)
        XCTAssertLessThanOrEqual(second.points.count, 4)
        if abs(first.points.last!.x - second.points.last!.x) < 64 {
            XCTAssertGreaterThanOrEqual(abs(first.points.last!.y - second.points.last!.y), 14)
        }
        for (a, b, c, d) in segmentPairs(first.points, second.points) {
            XCTAssertFalse(WorkEdgeRoute.sharesLane(a, b, c, d))
        }
    }

    func testArrowheadHasStraightClearanceAfterFinalCorner() {
        let source = CGRect(x: 500, y: 20, width: 270, height: 92)
        let target = CGRect(x: 322, y: 350, width: 500, height: 92)
        let obstacle = CGRect(x: 500, y: 140, width: 270, height: 160)
        let occupied = [[CGPoint(x: 318, y: 66), CGPoint(x: 318, y: 396), CGPoint(x: 290, y: 396)]]
        let route = WorkEdgeRoute(source: source, target: target, obstacles: [obstacle], occupied: occupied)
        let end = route.points.last!, corner = route.points[route.points.count - 2]
        XCTAssertGreaterThanOrEqual(hypot(end.x - corner.x, end.y - corner.y), 18)
        XCTAssertLessThanOrEqual(route.points.count, 4)
    }

    func testOpposingBranchesChooseNoncrossingLanesInEitherOrder() {
        let source = CGRect(x: 0, y: 20, width: 270, height: 92)
        let left = CGRect(x: -160, y: 350, width: 560, height: 92)
        let right = CGRect(x: 450, y: 350, width: 230, height: 120)
        let blocker = CGRect(x: 0, y: 140, width: 270, height: 160)
        for targets in [[left, right], [right, left]] {
            let first = WorkEdgeRoute(source: source, target: targets[0], obstacles: [targets[1], blocker])
            let second = WorkEdgeRoute(source: source, target: targets[1], obstacles: [targets[0], blocker], occupied: [first.points])
            XCTAssertLessThanOrEqual(first.points.count, 4)
            XCTAssertLessThanOrEqual(second.points.count, 4)
            for (a, b, c, d) in segmentPairs(first.points, second.points) {
                XCTAssertFalse(WorkEdgeRoute.crosses(a, b, c, d))
                XCTAssertFalse(WorkEdgeRoute.sharesLane(a, b, c, d))
            }
        }
    }

    func testBatchRoutingRevisitsSharedSourcePorts() {
        let frames = [
            "source": CGRect(x: 636, y: 572, width: 270, height: 92),
            "left": CGRect(x: 298, y: 846, width: 270, height: 92),
            "right": CGRect(x: 636, y: 832, width: 500, height: 92),
            "obstacle": CGRect(x: 636, y: 680, width: 270, height: 120)
        ]
        let layout = RoutingSpace(frames: frames, representatives: Dictionary(uniqueKeysWithValues: frames.keys.map { ($0, $0) }))
        let edges = ["left", "right"].map { WorkEdge(from: "source", to: $0, kind: .depends, source: .linear) }
        let result = WorkEdgeRoute.plan(edges: edges, layout: layout)
        let reverse = WorkEdgeRoute.plan(edges: Array(edges.reversed()), layout: layout)
        XCTAssertEqual(result.mapValues(\.points), reverse.mapValues(\.points))
        let first = result[edges[0].id]!.points, second = result[edges[1].id]!.points
        XCTAssertLessThanOrEqual(first.count, 4)
        XCTAssertLessThanOrEqual(second.count, 4)
        for (a, b, c, d) in segmentPairs(first, second) { XCTAssertFalse(WorkEdgeRoute.crosses(a, b, c, d)) }
    }

}
