import XCTest
import LockInCore
@testable import LockIn
import LockInTestSupport

final class WorkPresentationTests: XCTestCase {
    func testViewsShareVisibilityAndCollapsedRepresentatives() {
        let graph = WorkGraph(merging: WorkGraphLayoutTests.fixture())
        for filter in WorkFilter.allCases {
            for collapsed: Set<String> in [[], ["root"], ["backend"], ["root", "client"]] {
                let presentation = WorkPresentation(graph: graph, filter: filter, collapsed: collapsed)
                XCTAssertEqual(Set(presentation.rows.map(\.id)), Set(presentation.layout.frames.keys))
                for edge in presentation.dependencies {
                    let from = presentation.layout.representatives[edge.from], to = presentation.layout.representatives[edge.to]
                    if from == nil || to == nil || from == to {
                        XCTAssertNil(presentation.routes[edge.id])
                    } else {
                        let points = presentation.routes[edge.id]?.points ?? []
                        XCTAssertTrue((2...4).contains(points.count))
                    }
                }
            }
        }
    }

    func testGeometryReservesSpaceForBothArrowApproachesAndLanes() {
        XCTAssertGreaterThanOrEqual(WorkGeometry.columnGap, WorkGeometry.arrowApproach * 2 + WorkGeometry.laneSpacing)
        XCTAssertGreaterThanOrEqual(WorkGeometry.arrowApproach - WorkGeometry.cornerRadius, WorkGeometry.arrowLength)
    }

    func testRegionCountsFollowTheFilterAndLabelsNameTheDrawnContainer() throws {
        let nodes = [
            WorkNode(id: "root", kind: .linear, title: "Root", label: "ENG-1"),
            WorkNode(id: "other", kind: .linear, title: "Other", label: "ENG-2"),
            WorkNode(id: "child", kind: .linear, title: "Child", label: "ENG-3"),
            WorkNode(id: "pr", kind: .pullRequest, title: "PR")
        ]
        let graph = WorkGraph(merging: WorkImportResult(nodes: nodes, snapshot: .fixture(id: "root", nodeIDs: nodes.map(\.id), edges: [
            WorkEdge(from: "root", to: "child", kind: .contains, source: .linear),
            WorkEdge(from: "other", to: "child", kind: .contains, source: .linear),
            WorkEdge(from: "child", to: "pr", kind: .implements, source: .linear)
        ])))
        let all = WorkPresentation(graph: graph, filter: .all, collapsed: [])
        let container = try XCTUnwrap(WorkHierarchy(graph: graph).parent["child"])
        XCTAssertTrue(try XCTUnwrap(all.layout.groups.first { $0.id == container }).memberIDs.contains("child"))
        XCTAssertEqual(all.containerLabels["child"], nodes.first { $0.id == container }?.label, "a sub-issue names the region it's drawn in")
        XCTAssertNil(all.containerLabels["pr"], "linked PRs carry no container label")
        XCTAssertEqual(all.regionSummaries["child"]?.prCount, 1)
        let issues = WorkPresentation(graph: graph, filter: .issues, collapsed: [])
        XCTAssertEqual(issues.regionSummaries["child"]?.prCount, 0, "PRs the filter hides aren't counted")
    }
}
