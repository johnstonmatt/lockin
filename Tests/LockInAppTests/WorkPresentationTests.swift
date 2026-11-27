import XCTest
import LockInCore
@testable import LockIn

final class WorkPresentationTests: XCTestCase {
    func testViewsShareVisibilityAndCollapsedRepresentatives() {
        var graph = WorkGraph(); graph.merge(WorkGraphLayoutTests.fixture())
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

    @MainActor func testStoreImportUsesInjectedProviderAndClearsBusyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory, runTimer: false, enforceBlocking: false, channel: nil)
        let seed = WorkGraphLayoutTests.fixture()
        let importer = WorkImporter(fetchLinear: { _ in seed }, enrichGitHub: { $0 })
        let operation = try store.importWork("ENG-200", using: importer)
        XCTAssertTrue(store.workImporting)
        _ = try await operation.value
        XCTAssertFalse(store.workImporting)
        XCTAssertNil(store.workImportTask)
        XCTAssertEqual(Set(store.sessionGraph.nodes.map(\.id)), Set(seed.nodes.map(\.id)))
    }
}
