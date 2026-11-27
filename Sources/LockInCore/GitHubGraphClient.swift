import Foundation

public struct GitHubGraphClient: Sendable {
    public typealias Request = @Sendable (String) async throws -> Data
    public typealias ReadinessRequest = @Sendable (PullRequestReference) async throws -> Data
    private let request: Request
    private let readinessRequest: ReadinessRequest?
    public init(request: @escaping Request, readinessRequest: ReadinessRequest? = nil) {
        self.request = request; self.readinessRequest = readinessRequest
    }
    struct Repository: Decodable { var full_name: String }
    struct RepositoryDetails: Decodable { var default_branch: String }
    struct Branch: Decodable { var ref: String; var repo: Repository?; var sha: String? }
    struct StackMembership: Decodable { var number: Int; var position: Int; var size: Int }
    struct PR: Decodable {
        var number: Int; var title: String; var html_url: String; var state: String
        var draft: Bool?; var merged_at: String?; var head: Branch; var base: Branch; var stack: StackMembership?
        var reference: PullRequestReference? { PullRequestReference(url: html_url) }
        var node: WorkNode? {
            guard let reference else { return nil }
            let merged = merged_at != nil
            return WorkNode(id: reference.nodeID, kind: .pullRequest, title: title, url: reference.url,
                label: reference.key, status: (merged ? WorkNode.PullRequestState.merged : state == "closed" ? .closed : draft == true ? .draft : .open).rawValue,
                resolved: merged, attention: state == "closed" && !merged)
        }
    }
    struct Stack: Decodable {
        struct Entry: Decodable { var number: Int }
        var pull_requests: [Entry]
    }
    /// The read-only REST endpoints the import uses, as `gh api` paths.
    enum Route {
        case pullRequest(PullRequestReference)
        case stack(repository: String, number: Int)
        case repository(String)
        /// Pull requests whose head is `branch` in the repository's owner, one page of 100.
        case pullsFrom(repository: String, branch: String, page: Int)

        var path: String {
            switch self {
            case .pullRequest(let reference): return "repos/\(reference.repository)/pulls/\(reference.number)"
            case .stack(let repository, let number): return "repos/\(repository)/stacks/\(number)"
            case .repository(let repository): return "repos/\(repository)"
            case .pullsFrom(let repository, let branch, let page):
                let owner = repository.split(separator: "/").first.map(String.init) ?? ""
                var query = URLComponents()
                query.queryItems = [URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "head", value: "\(owner):\(branch)"),
                                    URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
                return "repos/\(repository)/pulls?\(query.percentEncodedQuery ?? "")"
            }
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ route: Route) async throws -> T {
        try JSONDecoder().decode(type, from: await request(route.path))
    }

    /// What a PR found to come before it.
    private struct Upstream {
        var references: [PullRequestReference] = []
        var edges: [WorkEdge] = []
        var warning: String?
    }

    /// A stack's PRs in order, read once per stack.
    private func stackUpstream(_ membership: StackMembership, repository: String, seen stacks: inout Set<String>) async throws -> Upstream {
        guard stacks.insert("\(repository.lowercased())#\(membership.number)").inserted else { return Upstream() }
        let stack = try await get(Stack.self, .stack(repository: repository, number: membership.number))
        guard stack.pull_requests.count == membership.size else { throw LockInError("GitHub returned an incomplete stack. Try refreshing again.") }
        let refs = stack.pull_requests.compactMap { PullRequestReference(url: "https://github.com/\(repository)/pull/\($0.number)") }
        return Upstream(references: refs, edges: zip(refs, refs.dropFirst()).map {
            WorkEdge(from: $0.nodeID, to: $1.nodeID, kind: .depends, source: .stack)
        })
    }

    /// The one PR whose head is this PR's base branch, unless the base is the repository's default branch.
    private func branchUpstream(_ pr: PR, _ reference: PullRequestReference, node: WorkNode,
                                defaultBranches: inout [String: String]) async throws -> Upstream {
        let repository = reference.repository.lowercased()
        let defaultBranch: String
        if let cached = defaultBranches[repository] {
            defaultBranch = cached
        } else {
            defaultBranch = try await get(RepositoryDetails.self, .repository(reference.repository)).default_branch
            defaultBranches[repository] = defaultBranch
        }
        // Integration branches are boundaries, not upstream feature PRs.
        guard pr.base.ref != defaultBranch else { return Upstream() }
        let candidates = try await branchCandidates(for: pr, repository: reference.repository)
        if candidates.count == 1, let upstream = candidates[0].reference {
            return Upstream(references: [upstream], edges: [WorkEdge(from: upstream.nodeID, to: node.id, kind: .depends, source: .branch)])
        }
        if candidates.count > 1 { return Upstream(warning: "Multiple PRs match the base branch of \(reference.key); no ordering was inferred.") }
        return Upstream()
    }

    private func branchCandidates(for pr: PR, repository: String) async throws -> [PR] {
        var found: [PR] = []
        for page in 1...20 {
            let batch = try await get([PR].self, .pullsFrom(repository: repository, branch: pr.base.ref, page: page))
            found += batch.filter {
                $0.number != pr.number && $0.head.repo?.full_name.lowercased() == pr.base.repo?.full_name.lowercased()
                    && $0.head.ref == pr.base.ref && ($0.state == "open" || $0.merged_at != nil)
            }
            if batch.count < 100 { return found }
        }
        throw LockInError("Too many PRs match the base branch to infer an order.")
    }

    public func enrich(_ imported: WorkImportResult) async throws -> WorkImportResult {
        var result = imported
        var nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        let associated = Set(result.snapshot.edges.filter { $0.kind == .implements }.map(\.to))
        var queue = result.nodes.compactMap { PullRequestReference(url: $0.url) }
        var visited = Set<String>(), stacks = Set<String>()
        var defaultBranches: [String: String] = [:]
        var edges: [WorkEdge] = []
        while !queue.isEmpty {
            try Task.checkCancellation()
            let reference = queue.removeFirst()
            guard visited.insert(reference.key).inserted else { continue }
            guard visited.count <= 400 else { throw LockInError("This import exceeds 400 PRs. Import a smaller tree.") }
            let pr: PR
            do { pr = try await get(PR.self, .pullRequest(reference)) }
            catch {
                if error is CancellationError { throw error }
                throw LockInError("Couldn't read \(reference.key). Check GitHub sign-in and repository access. The saved graph is unchanged.")
            }
            guard var node = pr.node else { throw LockInError("GitHub returned an invalid pull request URL.") }
            node.context = !associated.contains(node.id)
            if !node.resolved && pr.state != "closed", let readinessRequest {
                do {
                    let data = try await readinessRequest(reference)
                    node.readiness = try GitHubReadinessResponse.decode(data, expectedHeadOID: pr.head.sha)
                } catch {
                    try Task.checkCancellation()
                    result.snapshot.warnings.append("Checks/reviews unavailable for \(reference.key): \(error.localizedDescription)")
                }
            }
            nodes[node.id] = node
            let upstream = if let membership = pr.stack {
                try await stackUpstream(membership, repository: reference.repository, seen: &stacks)
            } else {
                try await branchUpstream(pr, reference, node: node, defaultBranches: &defaultBranches)
            }
            queue += upstream.references
            edges += upstream.edges
            if let warning = upstream.warning { result.snapshot.warnings.append(warning) }
        }
        result.nodes = nodes.values.sorted { $0.id < $1.id }
        result.snapshot.nodeIDs = nodes.keys.sorted()
        result.snapshot.edges += edges
        result.snapshot.refreshedAt = Date()
        return result
    }
}
