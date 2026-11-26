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
                label: reference.key, status: merged ? "Merged" : state == "closed" ? "Closed" : draft == true ? "Draft" : "Open",
                resolved: merged, attention: state == "closed" && !merged)
        }
    }
    struct Stack: Decodable {
        struct Entry: Decodable { var number: Int }
        var pull_requests: [Entry]
    }
    private func get<T: Decodable>(_ type: T.Type, _ route: String) async throws -> T {
        try JSONDecoder().decode(type, from: await request(route))
    }
    private func branchCandidates(for pr: PR, repository: String) async throws -> [PR] {
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "head", value: "\(owner):\(pr.base.ref)"),
                                 URLQueryItem(name: "per_page", value: "100")]
        var found: [PR] = []
        for page in 1...20 {
            let batch = try await get([PR].self, "repos/\(repository)/pulls?\(components.percentEncodedQuery!)&page=\(page)")
            found += batch.filter {
                $0.number != pr.number && $0.head.repo?.full_name.lowercased() == pr.base.repo?.full_name.lowercased()
                    && $0.head.ref == pr.base.ref && ($0.state == "open" || $0.merged_at != nil)
            }
            if batch.count < 100 { return found }
        }
        throw WorkImportError("Too many PRs match the base branch to infer an order.")
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
            guard visited.count <= 400 else { throw WorkImportError("This import exceeds 400 PRs. Import a smaller tree.") }
            let pr: PR
            do { pr = try await get(PR.self, "repos/\(reference.repository)/pulls/\(reference.number)") }
            catch {
                if error is CancellationError { throw error }
                throw WorkImportError("Couldn't read \(reference.key). Check GitHub sign-in and repository access. The saved graph is unchanged.")
            }
            guard var node = pr.node else { throw WorkImportError("GitHub returned an invalid pull request URL.") }
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
            if let membership = pr.stack {
                let key = "\(reference.repository.lowercased())#\(membership.number)"
                if stacks.insert(key).inserted {
                    let stack = try await get(Stack.self, "repos/\(reference.repository)/stacks/\(membership.number)")
                    guard stack.pull_requests.count == membership.size else { throw WorkImportError("GitHub returned an incomplete stack. Try refreshing again.") }
                    let refs = stack.pull_requests.compactMap {
                        PullRequestReference(url: "https://github.com/\(reference.repository)/pull/\($0.number)")
                    }
                    queue += refs
                    for (first, second) in zip(refs, refs.dropFirst()) {
                        edges.append(WorkEdge(from: first.nodeID, to: second.nodeID, kind: .depends, source: .stack))
                    }
                }
            } else {
                let repository = reference.repository.lowercased()
                let defaultBranch: String
                if let cached = defaultBranches[repository] {
                    defaultBranch = cached
                } else {
                    let details = try await get(RepositoryDetails.self, "repos/\(reference.repository)")
                    defaultBranch = details.default_branch
                    defaultBranches[repository] = defaultBranch
                }
                // Integration branches are boundaries, not upstream feature PRs.
                guard pr.base.ref != defaultBranch else { continue }
                let candidates = try await branchCandidates(for: pr, repository: reference.repository)
                if candidates.count == 1, let upstream = candidates[0].reference {
                    queue.append(upstream)
                    edges.append(WorkEdge(from: upstream.nodeID, to: node.id, kind: .depends, source: .branch))
                } else if candidates.count > 1 {
                    result.snapshot.warnings.append("Multiple PRs match the base branch of \(reference.key); no ordering was inferred.")
                }
            }
        }
        result.nodes = nodes.values.sorted { $0.id < $1.id }
        result.snapshot.nodeIDs = nodes.keys.sorted()
        result.snapshot.edges += edges
        result.snapshot.refreshedAt = Date()
        return result
    }
}
