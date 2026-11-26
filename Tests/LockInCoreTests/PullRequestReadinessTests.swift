import XCTest
@testable import LockInCore

final class PullRequestReadinessTests: XCTestCase {
    private func readiness(_ checks: String? = "SUCCESS", review: String? = "REVIEW_REQUIRED",
                           merge: String = "BLOCKED", draft: Bool = false) -> PullRequestReadiness {
        PullRequestReadiness(checks: checks, reviewDecision: review, mergeState: merge, isDraft: draft, headOID: "abc")
    }

    func testDraftIsDistinctEvenWhenChecksFail() {
        XCTAssertEqual(readiness("FAILURE", draft: true).status, .draft)
        XCTAssertEqual(readiness("SUCCESS", review: "APPROVED", merge: "CLEAN", draft: true).status, .draft)
    }
    func testFailuresTakePrecedenceOverApproval() {
        for check in ["FAILURE", "ERROR"] {
            XCTAssertEqual(readiness(check, review: "APPROVED", merge: "CLEAN").status, .failing)
        }
    }
    func testPassingDoesNotImplyReviewRequirementsAreMet() {
        for review in ["REVIEW_REQUIRED", "CHANGES_REQUESTED", "APPROVED"] {
            XCTAssertEqual(readiness(review: review).status, .passing)
        }
        XCTAssertEqual(readiness(review: "APPROVED", merge: "UNKNOWN").status, .passing)
        XCTAssertEqual(readiness(review: "APPROVED", merge: "BEHIND").status, .passing)
    }
    func testReadyRequiresPassingChecksAndConfirmedGates() {
        XCTAssertEqual(readiness(review: "APPROVED", merge: "CLEAN").status, .ready)
        XCTAssertEqual(readiness(review: nil, merge: "CLEAN").status, .ready, "GitHub confirms no outstanding review gates")
        XCTAssertEqual(readiness(nil, review: nil, merge: "CLEAN").status, .ready, "no required checks or reviews")
        XCTAssertEqual(readiness("PENDING", review: "APPROVED", merge: "CLEAN").status, .pending)
        XCTAssertEqual(readiness(nil, review: "APPROVED", merge: "BLOCKED").status, .pending)
    }
    func testPendingAndUnknownResultsNeverLookPassing() {
        for checks in ["PENDING", "EXPECTED", "FUTURE_STATE"] {
            XCTAssertEqual(readiness(checks).status, .pending)
        }
        XCTAssertEqual(readiness(nil).status, .pending)
    }
    func testUnstableRequiresPassingRequiredChecksAndSatisfiedReviews() {
        XCTAssertEqual(readiness(review: "APPROVED", merge: "UNSTABLE").status, .ready)
        XCTAssertEqual(readiness(review: nil, merge: "UNSTABLE").status, .ready)
        for review in ["REVIEW_REQUIRED", "CHANGES_REQUESTED"] {
            XCTAssertEqual(readiness(review: review, merge: "UNSTABLE").status, .passing)
        }
        XCTAssertEqual(readiness("FAILURE", review: "APPROVED", merge: "UNSTABLE").status, .failing)
        XCTAssertEqual(readiness("PENDING", review: "APPROVED", merge: "UNSTABLE").status, .pending)
        XCTAssertEqual(readiness(review: "APPROVED", merge: "UNSTABLE", draft: true).status, .draft)
    }
    func testLinearStatusIsHiddenAndTerminalPRsStayTerminal() {
        let issue = WorkNode(id: "issue", kind: .linear, title: "Issue", status: "In review")
        XCTAssertNil(issue.displayStatus)
        var pr = WorkNode(id: "pr", kind: .pullRequest, title: "PR", status: "Open")
        XCTAssertEqual(pr.displayStatus, .pending, "cached lifecycle alone is not a readiness signal")
        pr.readiness = readiness(review: "APPROVED", merge: "CLEAN")
        XCTAssertEqual(pr.displayStatus, .ready)
        pr.status = "Closed"
        XCTAssertEqual(pr.displayStatus, .closed)
        pr.resolved = true
        XCTAssertEqual(pr.displayStatus, .merged)
    }
    func testReadinessPersistsAndOldNodesDecodeWithoutIt() throws {
        var pr = WorkNode(id: "pr", kind: .pullRequest, title: "PR")
        let oldData = try FileFormat.encoder.encode(pr)
        XCTAssertNil(try FileFormat.decoder.decode(WorkNode.self, from: oldData).readiness)
        pr.readiness = readiness()
        let data = try FileFormat.encoder.encode(pr)
        XCTAssertEqual(try FileFormat.decoder.decode(WorkNode.self, from: data), pr)
    }
    private func response(head: String = "abc", commit: String = "abc", error: Bool = false, checks: [[String: Any]] = [], more: Bool = false, merge: String = "CLEAN") throws -> Data {
        var object: [String: Any] = ["data": ["repository": ["pullRequest": [
            "headRefOid": head, "isDraft": false, "reviewDecision": "APPROVED", "mergeStateStatus": merge,
            "commits": ["nodes": [["commit": ["oid": commit, "statusCheckRollup": ["contexts": ["pageInfo": ["hasNextPage": more], "nodes": checks]]]]]]
        ]]]]
        if error { object["errors"] = [["message": "denied"]] }
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testDecoderChecksHeadRevisionAndRejectsPartialGraphQLResponses() throws {
        XCTAssertEqual(try GitHubReadinessResponse.decode(response(), expectedHeadOID: "abc").status, .ready)
        XCTAssertThrowsError(try GitHubReadinessResponse.decode(response(), expectedHeadOID: "new-head"))
        XCTAssertThrowsError(try GitHubReadinessResponse.decode(response(commit: "old-head"), expectedHeadOID: "abc"))
        XCTAssertThrowsError(try GitHubReadinessResponse.decode(response(error: true), expectedHeadOID: "abc"))
    }
    private func check(_ conclusion: String, required: Bool = true, name: String = "CI") -> [String: Any] {
        ["name": name, "status": conclusion == "RUNNING" ? "IN_PROGRESS" : "COMPLETED",
         "conclusion": conclusion, "isRequired": required]
    }
    func testRequiredChecksDetermineStatusAndOptionalFailuresDoNotBlock() throws {
        let data = try response(checks: [check("SUCCESS"), check("CANCELLED", required: false, name: "size")])
        var result = try GitHubReadinessResponse.decode(data, expectedHeadOID: "abc")
        result.reviewDecision = "REVIEW_REQUIRED"; result.mergeState = "BLOCKED"
        XCTAssertEqual(result.status, .passing)
        XCTAssertEqual(try FileFormat.decoder.decode(PullRequestReadiness.self, from: FileFormat.encoder.encode(result)), result)
        for conclusion in ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"] {
            XCTAssertEqual(try GitHubReadinessResponse.decode(response(checks: [check(conclusion)]), expectedHeadOID: "abc").status, .failing)
        }
        XCTAssertEqual(try GitHubReadinessResponse.decode(response(checks: [check("RUNNING")]), expectedHeadOID: "abc").status, .pending)
        XCTAssertEqual(try GitHubReadinessResponse.decode(response(checks: [check("RUNNING", required: false)]), expectedHeadOID: "abc").status, .ready)
        XCTAssertEqual(try GitHubReadinessResponse.decode(response(checks: [check("SKIPPED"), check("NEUTRAL")]), expectedHeadOID: "abc").status, .ready)
    }
    func testOptionalCancelledCheckDoesNotPreventUnstablePRBeingReady() throws {
        let data = try response(checks: [check("SUCCESS"), check("CANCELLED", required: false, name: "size")], merge: "UNSTABLE")
        let result = try GitHubReadinessResponse.decode(data, expectedHeadOID: "abc")
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.reviewDecision, "APPROVED")
        XCTAssertEqual(result.checks, "SUCCESS")
    }
    func testLegacyStatusContextsAndUnknownCheckStates() throws {
        for (state, expected) in [("SUCCESS", PullRequestReadiness.Status.ready), ("ERROR", .failing), ("PENDING", .pending)] {
            let context: [String: Any] = ["context": "external CI", "state": state, "isRequired": true]
            XCTAssertEqual(try GitHubReadinessResponse.decode(response(checks: [context]), expectedHeadOID: "abc").status, expected)
        }
        XCTAssertEqual(try GitHubReadinessResponse.decode(response(checks: [check("FUTURE_STATE")]), expectedHeadOID: "abc").status, .pending)
    }
    func testAllPagesAreRequiredAndMustReferToSameHead() throws {
        let first = try response(checks: [check("SUCCESS")], more: true)
        let second = try response(checks: [check("FAILURE")])
        func pages(_ a: Data, _ b: Data) -> Data { Data("[".utf8) + a + Data(",".utf8) + b + Data("]".utf8) }
        XCTAssertEqual(try GitHubReadinessResponse.decode(pages(first, second), expectedHeadOID: "abc").status, .failing)
        XCTAssertThrowsError(try GitHubReadinessResponse.decode(first, expectedHeadOID: "abc"))
        XCTAssertThrowsError(try GitHubReadinessResponse.decode(pages(first, response(head: "new", commit: "new")), expectedHeadOID: nil))
    }

}
