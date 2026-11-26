import Foundation

extension WorkNode {
    public enum DisplayStatus: String, Sendable {
        case open = "Open", done = "Done", merged = "Merged", closed = "Closed"
        case draft = "Draft", pending = "Pending", failing = "Failing", passing = "Passing", ready = "Ready"

        init(_ readiness: PullRequestReadiness.Status) {
            switch readiness {
            case .draft: self = .draft
            case .pending: self = .pending
            case .failing: self = .failing
            case .passing: self = .passing
            case .ready: self = .ready
            }
        }
    }

    /// Linear workflow statuses are not shown; PRs show readiness rather than their raw lifecycle.
    public var displayStatus: DisplayStatus? {
        switch kind {
        case .linear: return nil
        case .local: return resolved ? .done : .open
        case .pullRequest:
            if resolved { return .merged }
            if status == "Closed" { return .closed }
            return readiness.map { DisplayStatus($0.status) } ?? (status == "Draft" ? .draft : .pending)
        }
    }

    public var statusExplanation: String {
        if kind != .pullRequest { return "" }
        if resolved { return "This PR is merged and satisfies its graph dependencies." }
        if status == "Closed" { return "This PR was closed without merging. Its dependencies are not satisfied." }
        return readiness?.explanation ?? "Check and review results are not available. Refresh to fetch them."
    }
}
