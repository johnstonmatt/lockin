import Foundation

public struct LinearGraphClient: Sendable {
    public typealias Request = @Sendable (String, [String: String]) async throws -> Data
    private let request: Request
    public init(request: @escaping Request) { self.request = request }

    public static func issueIdentifier(from input: String) -> String? {
        let input = input.trimmed
        if input.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil { return input.uppercased() }
        guard let url = URL(string: input), url.scheme == "https", url.host?.lowercased() == "linear.app" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(of: "issue"), index + 1 < parts.count else { return nil }
        return issueIdentifier(from: parts[index + 1])
    }

    struct State: Decodable { var name: String; var type: String }
    struct Issue: Decodable {
        var id: String; var identifier: String; var title: String; var url: String; var state: State; var archivedAt: String?
        var node: WorkNode {
            WorkNode(id: "linear:\(id)", kind: .linear, title: title, url: url, label: identifier,
                     status: archivedAt == nil ? state.name : "Archived · " + state.name, resolved: state.type == "completed", attention: state.type == "canceled" || archivedAt != nil)
        }
    }
    struct Relation: Decodable { var type: String; var issue: Issue; var relatedIssue: Issue }
    struct Attachment: Decodable { var url: String; var title: String }
    struct Page<T: Decodable>: Decodable {
        var nodes: [T]; var pageInfo: PageInfo
    }
    struct PageInfo: Decodable { var endCursor: String?; var hasNextPage: Bool }
    private static let fields = "id identifier title url archivedAt state { name type }"

    private func decode<T: Decodable>(_ type: T.Type, query: String, variables: [String: String], path: [String]) async throws -> T {
        let bytes = try await request(query, variables)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw WorkImportError("Linear returned an invalid response.")
        }
        if let errors = object["errors"] as? [Any], !errors.isEmpty {
            throw WorkImportError("Linear couldn't read this issue. Check the API key and its team access.")
        }
        var value: Any = object
        for component in ["data"] + path {
            guard let next = (value as? [String: Any])?[component], !(next is NSNull) else {
                throw WorkImportError("Linear couldn't find this issue or you don't have access to it.")
            }
            value = next
        }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private func issue(_ identifier: String) async throws -> Issue {
        try await decode(Issue.self, query: "query($id:String!){ issue(id:$id){ \(Self.fields) } }",
                         variables: ["id": identifier], path: ["issue"])
    }
    private func pages<T: Decodable>(_ type: T.Type, field: String, fields: String, id: String) async throws -> [T] {
        var result: [T] = [], cursor: String?, seen = Set<String>()
        repeat {
            var variables = ["id": id]
            if let cursor { variables["after"] = cursor }
            let archiveArgument = field == "children" ? ",includeArchived:true" : ""
            let query = "query($id:String!,$after:String){issue(id:$id){\(field)(first:100,after:$after\(archiveArgument)){nodes{\(fields)} pageInfo{endCursor hasNextPage}}}}"
            let page = try await decode(Page<T>.self, query: query, variables: variables, path: ["issue", field])
            result += page.nodes
            guard result.count <= 2000 else { throw WorkImportError("This issue has too many relationships to import at once. Import a smaller subtree.") }
            if !page.pageInfo.hasNextPage { break }
            guard let next = page.pageInfo.endCursor, seen.insert(next).inserted else {
                throw WorkImportError("Linear returned an invalid pagination cursor.")
            }
            cursor = next
        } while true
        return result
    }

    public func fetch(_ input: String) async throws -> WorkImportResult {
        guard let identifier = Self.issueIdentifier(from: input) else { throw WorkImportError("Enter a Linear issue URL or issue identifier.") }
        let root = try await issue(identifier)
        var queue = [root], seen = Set<String>(), nodes: [String: WorkNode] = [:], edges: [WorkEdge] = []
        while !queue.isEmpty {
            try Task.checkCancellation()
            let current = queue.removeFirst()
            guard seen.insert(current.id).inserted else { continue }
            guard seen.count <= 250 else { throw WorkImportError("This tree exceeds 250 issues. Import a smaller subtree.") }
            nodes[current.node.id] = current.node
            let children = try await pages(Issue.self, field: "children", fields: Self.fields, id: current.id)
            for child in children {
                edges.append(WorkEdge(from: current.node.id, to: child.node.id, kind: .contains, source: .linear))
                queue.append(child)
            }
            let attachments = try await pages(Attachment.self, field: "attachments", fields: "url title", id: current.id)
            for attachment in attachments {
                guard let pr = PullRequestReference(url: attachment.url) else { continue }
                let id = pr.nodeID
                if nodes[id] == nil {
                    nodes[id] = WorkNode(id: id, kind: .pullRequest, title: attachment.title, url: pr.url,
                                         label: pr.key, status: "Not fetched")
                }
                edges.append(WorkEdge(from: current.node.id, to: id, kind: .implements, source: .linear))
            }
            for field in ["relations", "inverseRelations"] {
                let relations = try await pages(Relation.self, field: field,
                    fields: "type issue { \(Self.fields) } relatedIssue { \(Self.fields) }", id: current.id)
                for relation in relations where relation.type == "blocks" {
                    for issue in [relation.issue, relation.relatedIssue] where nodes[issue.node.id] == nil {
                        var node = issue.node; node.context = true; nodes[node.id] = node
                    }
                    edges.append(WorkEdge(from: relation.issue.node.id, to: relation.relatedIssue.node.id, kind: .depends, source: .linear))
                }
            }
        }
        return WorkImportResult(nodes: nodes.values.sorted { $0.id < $1.id },
            snapshot: WorkImport(id: root.node.id, url: root.url, nodeIDs: nodes.keys.sorted(), edges: edges.uniqued(by: \.id)))
    }
}
