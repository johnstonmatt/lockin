import Foundation

public struct PullRequestReadiness: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case passing = "Passing", failing = "Failing", ready = "Ready", pending = "Pending", draft = "Draft"
    }
    public var checks: String?
    public var reviewDecision: String?
    public var mergeState: String
    public var isDraft: Bool
    public var headOID: String
    /// Spelled out so renaming a property can't change work-graph.json.
    enum CodingKeys: String, CodingKey { case checks, reviewDecision, mergeState, isDraft, headOID }
    public init(checks: String?, reviewDecision: String?, mergeState: String, isDraft: Bool, headOID: String) {
        self.checks = checks; self.reviewDecision = reviewDecision; self.mergeState = mergeState
        self.isDraft = isDraft; self.headOID = headOID
    }
    public var status: Status {
        if isDraft { return .draft }
        if checks == "FAILURE" || checks == "ERROR" { return .failing }
        // UNSTABLE is mergeable with non-passing checks; only required checks gate readiness.
        let mergeable = mergeState == "CLEAN" || mergeState == "UNSTABLE"
        let reviewsSatisfied = reviewDecision == "APPROVED" || reviewDecision == nil
        if mergeable && reviewsSatisfied && (checks == "SUCCESS" || checks == nil) { return .ready }
        if checks == "SUCCESS" { return .passing }
        return .pending
    }
    public var explanation: String {
        if isDraft { return "This PR is a draft. Mark it ready for review in GitHub when it is ready." }
        if status == .failing { return "One or more required checks failed. Required reviews cannot override failing checks." }
        if status == .ready { return "Checks and required reviews are satisfied. GitHub reports no outstanding merge gates. Graph prerequisites are tracked separately." }
        let checkMessage = checks == "SUCCESS" ? "Required checks are passing." : checks == nil
            ? "No check result has been confirmed." : "Required checks are pending or still running."
        let reviewMessage: String
        switch reviewDecision {
        case "REVIEW_REQUIRED": reviewMessage = "Required reviews are still outstanding."
        case "CHANGES_REQUESTED": reviewMessage = "A reviewer has requested changes."
        case "APPROVED": reviewMessage = "GitHub reports approval."
        default: reviewMessage = "Review requirements have not been confirmed."
        }
        let gateMessage: String
        switch mergeState {
        case "BLOCKED": gateMessage = "GitHub reports outstanding merge requirements."
        case "BEHIND": gateMessage = "The branch is behind its base."
        case "DIRTY": gateMessage = "The branch has merge conflicts."
        case "UNKNOWN": gateMessage = "GitHub is still determining merge requirements."
        default: gateMessage = ""
        }
        return [checkMessage, reviewMessage, gateMessage].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
