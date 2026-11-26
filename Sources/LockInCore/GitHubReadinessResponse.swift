import Foundation

public enum GitHubReadinessResponse {
    public static let query = """
    query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          headRefOid isDraft reviewDecision mergeStateStatus
          commits(last:1){nodes{commit{oid statusCheckRollup{
            contexts(first:100,after:$endCursor){
              pageInfo{hasNextPage endCursor}
              nodes{
                ... on CheckRun{status conclusion isRequired(pullRequestNumber:$number)}
                ... on StatusContext{state isRequired(pullRequestNumber:$number)}
              }
            }
          }}}}
        }
      }
    }
    """

    private struct Check: Decodable {
        var status: String?
        var conclusion: String?
        var state: String?
        var isRequired: Bool

        var outcome: String {
            if let state {
                switch state {
                case "SUCCESS": return "SUCCESS"
                case "FAILURE", "ERROR": return "FAILURE"
                default: return "PENDING"
                }
            }
            guard status == "COMPLETED" else { return "PENDING" }
            switch conclusion {
            case "SUCCESS", "SKIPPED", "NEUTRAL": return "SUCCESS"
            case "FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": return "FAILURE"
            default: return "PENDING"
            }
        }
    }

    public static func decode(_ data: Data, expectedHeadOID: String?) throws -> PullRequestReadiness {
        struct Envelope: Decodable {
            struct QueryData: Decodable {
                struct Repository: Decodable { var pullRequest: PR? }
                var repository: Repository?
            }
            struct Problem: Decodable { var message: String }
            var data: QueryData?
            var errors: [Problem]?
        }
        struct PR: Decodable {
            struct Commits: Decodable {
                struct Node: Decodable {
                    struct Commit: Decodable {
                        struct Rollup: Decodable {
                            struct Contexts: Decodable {
                                struct PageInfo: Decodable { var hasNextPage: Bool }
                                var pageInfo: PageInfo
                                var nodes: [Check]
                            }
                            var contexts: Contexts
                        }
                        var oid: String
                        var statusCheckRollup: Rollup?
                    }
                    var commit: Commit
                }
                var nodes: [Node]
            }
            var headRefOid: String
            var isDraft: Bool
            var reviewDecision: String?
            var mergeStateStatus: String
            var commits: Commits
        }
        let decoder = JSONDecoder()
        let pages = data.first(where: { ![9, 10, 13, 32].contains($0) }) == UInt8(ascii: "[")
            ? try decoder.decode([Envelope].self, from: data)
            : [try decoder.decode(Envelope.self, from: data)]
        var result: PullRequestReadiness?
        var checks: [Check] = []
        for (index, envelope) in pages.enumerated() {
            guard envelope.errors?.isEmpty != false, let pr = envelope.data?.repository?.pullRequest else {
                throw WorkImportError("GitHub couldn't confirm checks and required reviews.")
            }
            guard let commit = pr.commits.nodes.last?.commit, commit.oid == pr.headRefOid,
                  expectedHeadOID == nil || expectedHeadOID == pr.headRefOid,
                  result == nil || result?.headOID == pr.headRefOid else {
                throw WorkImportError("The PR changed while fetching checks. Refresh to read the latest revision.")
            }
            let contexts = commit.statusCheckRollup?.contexts
            guard contexts?.pageInfo.hasNextPage == (index < pages.count - 1) || (contexts == nil && pages.count == 1) else {
                throw WorkImportError("GitHub returned incomplete checks. Refresh to try again.")
            }
            checks += contexts?.nodes ?? []
            result = PullRequestReadiness(checks: nil, reviewDecision: pr.reviewDecision,
                                          mergeState: pr.mergeStateStatus, isDraft: pr.isDraft, headOID: pr.headRefOid)
        }
        guard var result else { throw WorkImportError("GitHub returned no check results.") }
        let required = checks.filter(\.isRequired)
        result.checks = required.contains { $0.outcome == "FAILURE" } ? "FAILURE"
            : required.contains { $0.outcome == "PENDING" } ? "PENDING" : "SUCCESS"
        return result
    }
}
