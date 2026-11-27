import XCTest
@testable import LockInCore
import LockInTestSupport

final class WorkImporterTests: XCTestCase {
    func testDirectPRImportSkipsLinearAndSelectsOnlyRequestedPR() async throws {
        let importer = WorkImporter(fetchLinear: { _ in throw LockInError("Linear must not run") }, enrichGitHub: { seed in
            var result = seed
            result.nodes[0].context = true
            result.nodes.append(WorkNode(id: "upstream", kind: .pullRequest, title: "Prerequisite", context: true))
            return result
        })
        let result = try await importer.fetch("https://github.com/org/repo/pull/12", preserving: [])
        XCTAssertEqual(result.snapshot.id, "github:org/repo#12")
        XCTAssertFalse(result.nodes[0].context)
        XCTAssertTrue(result.nodes[1].context)
    }

    private func fixture() -> WorkImportResult {
        let node = WorkNode(id: "root", kind: .linear, title: "Feature")
        return WorkImportResult(nodes: [node], snapshot: .fixture(id: node.id, nodeIDs: [node.id], edges: []))
    }

    func testFirstImportRetainsLinearTreeWhenGitHubIsUnavailable() async throws {
        let seed = fixture()
        let importer = WorkImporter(fetchLinear: { _ in seed }, enrichGitHub: { _ in throw LockInError("Unavailable") })
        let result = try await importer.fetch("ENG-1", preserving: [])
        XCTAssertEqual(result.nodes, seed.nodes)
        XCTAssertEqual(result.snapshot.warnings, ["PR details are incomplete: Unavailable"])
    }

    func testRefreshNeverReturnsAPartialReplacement() async {
        let seed = fixture()
        let importer = WorkImporter(fetchLinear: { _ in seed }, enrichGitHub: { _ in throw LockInError("Unavailable") })
        do {
            _ = try await importer.fetch("ENG-1", preserving: [seed.snapshot.id])
            XCTFail("A failed refresh must preserve the saved import")
        } catch { XCTAssertEqual(error.localizedDescription, "Unavailable") }
    }

    func testCancellationCannotBecomeAPartialImportWarning() async {
        let seed = fixture()
        let importer = WorkImporter(fetchLinear: { _ in seed }, enrichGitHub: { _ in throw CancellationError() })
        do {
            _ = try await importer.fetch("ENG-1", preserving: [])
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSuccessfulImportReturnsEnrichedWork() async throws {
        let seed = fixture()
        let importer = WorkImporter(fetchLinear: { _ in seed }, enrichGitHub: { value in
            var result = value
            result.nodes.append(WorkNode(id: "pr", kind: .pullRequest, title: "Implementation"))
            return result
        })
        let result = try await importer.fetch("ENG-1", preserving: [])
        XCTAssertEqual(result.nodes.map(\.id), ["root", "pr"])
        XCTAssertTrue(result.snapshot.warnings.isEmpty)
    }
}
