import XCTest
@testable import LockInCore
import LockInTestSupport

private actor LinearFixture {
    var calls: [(String, [String: String])] = []
    func issue(_ id: String) -> [String: Any] {
        ["id": id, "identifier": "ENG-\(id)", "title": "Issue \(id)", "url": "https://linear.app/test/issue/ENG-\(id)",
         "state": ["name": "In progress", "type": "started"]]
    }
    func page(_ field: String, id: String, after: String?) -> [String: Any] {
        var nodes: [[String: Any]] = []
        var more = false
        if field == "children" && id == "1" {
            nodes = [issue(after == nil ? "2" : "3")]
            more = after == nil
        } else if field == "attachments" && ["2", "3"].contains(id) {
            nodes = [["title": "Shared PR", "url": "https://github.com/acme/app/pull/12"],
                     ["title": "Document", "url": "https://example.com/readme"]]
        } else if field == "inverseRelations" && id == "2" {
            nodes = [["type": "blocks", "issue": issue("9"), "relatedIssue": issue("2")]]
        }
        return ["nodes": nodes, "pageInfo": ["hasNextPage": more, "endCursor": more ? "next-page" as Any : NSNull()]]
    }
    /// Answers an issue with the first page of each connection, or one later page of a single connection.
    func request(_ query: String, _ variables: [String: String]) throws -> Data {
        calls.append((query, variables))
        let id = variables["id"] == "ENG-1" ? "1" : variables["id"]!
        let fields = ["children", "attachments", "relations", "inverseRelations"].filter { query.contains("{\($0)(") || query.contains(" \($0)(") }
        var object: [String: Any] = fields.count > 1 ? issue(id) : [:]
        for field in fields { object[field] = page(field, id: id, after: variables["after"]) }
        return try JSONSerialization.data(withJSONObject: ["data": ["issue": object]])
    }
}

private actor GitHubFixture {
    var calls: [String] = []
    let stack: Bool
    let ambiguous: Bool
    let defaultBranch: String
    let baseBranch: String
    init(stack: Bool = true, ambiguous: Bool = false, defaultBranch: String = "main", baseBranch: String = "branch-11") {
        self.stack = stack; self.ambiguous = ambiguous
        self.defaultBranch = defaultBranch; self.baseBranch = baseBranch
    }
    func pr(_ number: Int, repository: String = "acme/app", head: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "number": number, "title": "PR \(number)", "html_url": "https://github.com/\(repository)/pull/\(number)",
            "state": number == 11 ? "closed" : "open", "draft": number == 12,
            "head": ["ref": head ?? "branch-\(number)", "repo": ["full_name": repository]],
            "base": ["ref": number == 12 ? baseBranch : defaultBranch, "repo": ["full_name": "acme/app"]]
        ]
        if number == 11 { value["merged_at"] = "2026-01-01T00:00:00Z" }
        if stack { value["stack"] = ["number": 7, "size": 2, "position": number == 11 ? 1 : 2] }
        return value
    }
    func request(_ route: String) throws -> Data {
        calls.append(route)
        let value: Any
        if route == "repos/acme/app" { value = ["default_branch": defaultBranch] }
        else if route.contains("/stacks/7") { value = ["pull_requests": [["number": 11], ["number": 12]]] }
        else if route.contains("?") {
            if route.contains("branch-11") {
                value = ambiguous ? [pr(11), pr(13, head: "branch-11")] : [pr(11), pr(14, repository: "fork/app", head: "branch-11")]
            } else { value = [] as [[String: Any]] }
        } else if route.hasSuffix("/11") { value = pr(11) }
        else { value = pr(12) }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

final class WorkImportClientTests: XCTestCase {
    private func seed() -> WorkImportResult {
        let node = WorkNode(id: "github:acme/app#12", kind: .pullRequest, title: "PR",
                            url: "https://github.com/acme/app/pull/12")
        return WorkImportResult(nodes: [node],
            snapshot: .fixture(id: "linear:1", url: "https://linear.app/a/issue/ENG-1", nodeIDs: [node.id],
                edges: [WorkEdge(from: "linear:1", to: node.id, kind: .implements, source: .linear)]))
    }
    func testLinearPaginatesTreeAndKeepsSharedPRAndExternalBlocker() async throws {
        let fixture = LinearFixture()
        let client = LinearGraphClient { query, variables in try await fixture.request(query, variables) }
        let result = try await client.fetch("https://linear.app/test/issue/ENG-1/title")
        XCTAssertEqual(Set(result.nodes.map(\.id)), ["linear:1", "linear:2", "linear:3", "linear:9", "github:acme/app#12"])
        XCTAssertEqual(result.snapshot.edges.filter { $0.kind == .implements }.count, 2)
        XCTAssertEqual(result.snapshot.edges.filter { $0.kind == .contains }.count, 2)
        XCTAssertTrue(try XCTUnwrap(result.nodes.first { $0.id == "linear:9" }).context)
        XCTAssertFalse(try XCTUnwrap(result.nodes.first { $0.id == "linear:2" }).context)
        XCTAssertTrue(result.snapshot.edges.contains { $0.from == "linear:9" && $0.to == "linear:2" && $0.kind == .depends })
        let calls = await fixture.calls
        XCTAssertTrue(calls.contains { $0.1["after"] == "next-page" })
        XCTAssertFalse(calls.contains { $0.1["id"] == "9" }, "context issues must not recursively expand")
        XCTAssertEqual(calls.count, 4, "one request per issue, plus one for the second page of children")
    }
    func testLinearGraphQLErrorsRejectPartialResponses() async {
        let client = LinearGraphClient { _, _ in Data(#"{"data":{"issue":null},"errors":[{"message":"denied"}]}"#.utf8) }
        do { _ = try await client.fetch("ENG-1"); XCTFail("Expected error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("team access")) }
    }
    func testStackExpansionUsesReadOnlyRoutesAndKeepsOutsidePRAsContext() async throws {
        let fixture = GitHubFixture()
        let client = GitHubGraphClient { route in try await fixture.request(route) }
        let result = try await client.enrich(seed())
        let first = try XCTUnwrap(result.nodes.first { $0.id == "github:acme/app#11" })
        let second = try XCTUnwrap(result.nodes.first { $0.id == "github:acme/app#12" })
        XCTAssertTrue(first.context)
        XCTAssertTrue(first.resolved)
        XCTAssertFalse(second.context)
        XCTAssertEqual(second.status, "Draft")
        XCTAssertTrue(result.snapshot.edges.contains {
            $0.from == first.id && $0.to == second.id && $0.source == .stack
        })
        let calls = await fixture.calls
        XCTAssertEqual(calls.filter { $0.contains("/stacks/") }.count, 1)
        XCTAssertFalse(calls.contains { $0.contains("?") }, "explicit stack order wins over branch inference")
    }
    func testBranchInferenceChecksRepositoryIdentity() async throws {
        let fixture = GitHubFixture(stack: false)
        let client = GitHubGraphClient { route in try await fixture.request(route) }
        let result = try await client.enrich(seed())
        let edges = result.snapshot.edges.filter { $0.source == .branch }
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].from, "github:acme/app#11")
        let calls = await fixture.calls
        XCTAssertEqual(calls.filter { $0 == "repos/acme/app" }.count, 1)
    }
    func testDefaultBranchStopsInferenceBeforeDeploymentPRLookup() async throws {
        let fixture = GitHubFixture(stack: false, ambiguous: true, defaultBranch: "develop", baseBranch: "develop")
        let client = GitHubGraphClient { route in try await fixture.request(route) }
        let result = try await client.enrich(seed())
        XCTAssertTrue(result.snapshot.warnings.isEmpty)
        XCTAssertTrue(result.snapshot.edges.filter { $0.kind == .depends }.isEmpty)
        let calls = await fixture.calls
        XCTAssertTrue(calls.contains("repos/acme/app"))
        XCTAssertFalse(calls.contains { $0.contains("?") })
    }
    func testExplicitStackStillAppliesWhenTargetingDefaultBranch() async throws {
        let fixture = GitHubFixture(defaultBranch: "develop", baseBranch: "develop")
        let client = GitHubGraphClient { route in try await fixture.request(route) }
        let result = try await client.enrich(seed())
        XCTAssertEqual(result.snapshot.edges.filter { $0.source == .stack }.count, 1)
        let calls = await fixture.calls
        XCTAssertFalse(calls.contains("repos/acme/app"))
    }
    func testAmbiguousBranchesDoNotInventOrdering() async throws {
        let fixture = GitHubFixture(stack: false, ambiguous: true)
        let client = GitHubGraphClient { route in try await fixture.request(route) }
        let result = try await client.enrich(seed())
        XCTAssertTrue(result.snapshot.edges.filter { $0.kind == .depends }.isEmpty)
        XCTAssertEqual(result.snapshot.warnings.count, 1)
    }
    func testEnrichmentFetchesReadinessAndDoesNotRetainStaleResultsOnFailure() async throws {
        let fixture = GitHubFixture()
        let response = try readinessResponse()
        let client = GitHubGraphClient(request: { route in try await fixture.request(route) },
                                       readinessRequest: { _ in response })
        let result = try await client.enrich(seed())
        let ready = try XCTUnwrap(result.nodes.first { $0.id == "github:acme/app#12" })
        XCTAssertEqual(ready.displayStatus, .ready)
        XCTAssertNil(result.nodes.first { $0.resolved }?.readiness, "merged PRs need no review query")
        let unavailable = GitHubGraphClient(request: { route in try await fixture.request(route) },
                                            readinessRequest: { _ in throw LockInError("Access denied") })
        let refreshed = try await unavailable.enrich(result)
        XCTAssertNil(refreshed.nodes.first { $0.id == ready.id }?.readiness)
        XCTAssertFalse(refreshed.snapshot.warnings.isEmpty)
    }

    func testInvalidURLsAreRejected() {
        XCTAssertNil(LinearGraphClient.issueIdentifier(from: "https://linear.app.evil.test/a/issue/A-1"))
        XCTAssertNil(PullRequestReference(url: "https://github.com.evil.test/a/b/pull/1"))
        XCTAssertNil(PullRequestReference(url: "https://github.com/a/b/issues/1"))
        XCTAssertEqual(LinearGraphClient.issueIdentifier(from: "eng-123"), "ENG-123")
    }
}
