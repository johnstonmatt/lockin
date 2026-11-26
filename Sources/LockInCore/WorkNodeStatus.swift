import Foundation


extension WorkNode {
    public var displayStatus: String? {
        switch kind {
        case .linear: return nil
        case .local: return resolved ? "Done" : "Open"
        case .pullRequest:
            if resolved { return "Merged" }
            if status == "Closed" { return "Closed" }
            return readiness?.status.rawValue ?? (status == "Draft" ? "Draft" : "Pending")
        }
    }
    public var statusExplanation: String {
        if kind != .pullRequest { return "" }
        if resolved { return "This PR is merged and satisfies its graph dependencies." }
        if status == "Closed" { return "This PR was closed without merging. Its dependencies are not satisfied." }
        return readiness?.explanation ?? "Check and review results are not available. Refresh to fetch them."
    }
}
