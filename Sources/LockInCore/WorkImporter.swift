import Foundation

/// Coordinates provider reads while preserving complete saved imports when a refresh fails.
public struct WorkImporter: Sendable {
    public typealias FetchLinear = @Sendable (String) async throws -> WorkImportResult
    public typealias EnrichGitHub = @Sendable (WorkImportResult) async throws -> WorkImportResult
    private let fetchLinear: FetchLinear
    private let enrichGitHub: EnrichGitHub

    public init(fetchLinear: @escaping FetchLinear, enrichGitHub: @escaping EnrichGitHub) {
        self.fetchLinear = fetchLinear
        self.enrichGitHub = enrichGitHub
    }

    public func fetch(_ input: String, preserving importedIDs: Set<String>) async throws -> WorkImportResult {
        try Task.checkCancellation()
        if let pr = PullRequestReference(url: input.trimmed) {
            let id = "github:\(pr.key)"
            let node = WorkNode(id: id, kind: .pullRequest, title: pr.key, url: pr.url, label: pr.key)
            var result = try await enrichGitHub(WorkImportResult(nodes: [node], snapshot:
                WorkImport(id: id, url: pr.url, nodeIDs: [id], edges: [])))
            for index in result.nodes.indices where result.nodes[index].id == id { result.nodes[index].context = false }
            try Task.checkCancellation()
            return result
        }
        let linear = try await fetchLinear(input)
        let result: WorkImportResult
        do {
            result = try await enrichGitHub(linear)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            guard !importedIDs.contains(linear.snapshot.id) else { throw error }
            var partial = linear
            partial.snapshot.warnings.append("PR details are incomplete: \(error.localizedDescription)")
            result = partial
        }
        try Task.checkCancellation()
        return result
    }
}
