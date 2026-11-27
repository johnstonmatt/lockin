import XCTest
import LockInCore
@testable import LockIn
import LockInTestSupport

/// What every laid-out work graph must satisfy: connectors avoid unrelated cards and each other, cards don't overlap,
/// regions contain their members, and a dependency's card sits above the work that depends on it.
func assertLayoutInvariants(_ presentation: WorkPresentation, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    let layout = presentation.layout, routes = presentation.routes
    XCTAssertEqual(WorkEdgeRoute.obstructionCost(routes: routes, edges: presentation.dependencies, layout: layout.routingSpace), 0,
                   "\(name): connectors must not cross unrelated cards or region headers", file: file, line: line)
    let routeIDs = routes.keys.sorted()
    for (index, firstID) in routeIDs.enumerated() {
        let first = routes[firstID]!.points
        for secondID in routeIDs.dropFirst(index + 1) {
            let second = routes[secondID]!.points
            for (a, b, c, d) in segmentPairs(first, second) where WorkEdgeRoute.crosses(a, b, c, d) {
                XCTFail("\(name): \(firstID) crosses \(secondID): \(first) / \(second)", file: file, line: line)
            }
        }
    }
    let frames = layout.frames.sorted { $0.key < $1.key }
    for (index, first) in frames.enumerated() {
        for second in frames.dropFirst(index + 1) where first.value.intersects(second.value) {
            XCTFail("\(name): cards \(first.key) and \(second.key) overlap", file: file, line: line)
        }
    }
    for group in layout.groups {
        for id in group.memberIDs {
            if let rect = layout.frames[id], !group.rect.contains(rect) {
                XCTFail("\(name): region \(group.id) must contain \(id)", file: file, line: line)
            }
        }
    }
    for edge in presentation.dependencies {
        if let source = layout.frames[edge.from], let target = layout.frames[edge.to], source.maxY >= target.minY {
            XCTFail("\(name): \(edge.from) must sit above \(edge.to), which depends on it", file: file, line: line)
        }
    }
}

/// Every pairing of a segment of `first` with a segment of `second`.
func segmentPairs(_ first: [CGPoint], _ second: [CGPoint]) -> [(CGPoint, CGPoint, CGPoint, CGPoint)] {
    zip(first, first.dropFirst()).flatMap { a, b in zip(second, second.dropFirst()).map { c, d in (a, b, c, d) } }
}

final class WorkLayoutInvariantTests: XCTestCase {
    /// `WorkRoutingRegressionTests` checks its own, larger fixture: laying it out takes seconds.
    func testFixturesSatisfyLayoutInvariants() {
        for (name, result) in [("nested branches", WorkGraphLayoutTests.fixture()), ("session graph", WorkGraphRenderTests.fixture())] {
            let graph = WorkGraph(merging: result)
            let presentation = WorkPresentation(graph: graph, filter: .all, collapsed: [])
            XCTAssertFalse(presentation.routes.isEmpty, "\(name) has connectors to check")
            assertLayoutInvariants(presentation, name)
        }
    }
}
