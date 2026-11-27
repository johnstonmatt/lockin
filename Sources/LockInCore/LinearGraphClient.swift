import Foundation

public struct LinearGraphClient: Sendable {
    public typealias Request = @Sendable (String, [String: String]) async throws -> Data
    private let request: Request
    public init(request: @escaping Request) { self.request = request }

    /// The issue an identifier ("ENG-12") or a Linear issue link names.
    public static func issueIdentifier(from input: String) -> String? {
        let input = input.trimmed
        return Link.isLinearIdentifier(input) ? input.uppercased() : Link.linearIssue(input)?.identifier
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
    private static let relationFields = "type issue { \(fields) } relatedIssue { \(fields) }"

    /// An issue with the first page of each connection the import follows, read in one request.
    struct Expanded: Decodable {
        var issue: Issue
        var children: Page<Issue>
        var attachments: Page<Attachment>
        var relations: Page<Relation>
        var inverseRelations: Page<Relation>
        private enum CodingKeys: CodingKey { case children, attachments, relations, inverseRelations }
        init(from decoder: Decoder) throws {
            issue = try Issue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            children = try container.decode(Page<Issue>.self, forKey: .children)
            attachments = try container.decode(Page<Attachment>.self, forKey: .attachments)
            relations = try container.decode(Page<Relation>.self, forKey: .relations)
            inverseRelations = try container.decode(Page<Relation>.self, forKey: .inverseRelations)
        }
    }
    private struct IssueData<T: Decodable>: Decodable { var issue: T? }
    /// The issue's one requested connection, whatever its name.
    private struct OnlyField<T: Decodable>: Decodable {
        struct Key: CodingKey {
            var stringValue: String; var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        var value: T
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No connection"))
            }
            value = try container.decode(T.self, forKey: key)
        }
    }

    private static func connection(_ field: String, _ fields: String) -> String {
        let archived = field == "children" ? ",includeArchived:true" : ""
        return "\(field)(first:100,after:$after\(archived)){nodes{\(fields)} pageInfo{endCursor hasNextPage}}"
    }

    private func decode<T: Decodable>(_ type: T.Type, query: String, variables: [String: String]) async throws -> T {
        let bytes = try await request(query, variables)
        guard let response = try? JSONDecoder().decode(GraphQLResponse<IssueData<T>>.self, from: bytes) else {
            throw LockInError("Linear returned an invalid response.")
        }
        if response.hasErrors { throw LockInError("Linear couldn't read this issue. Check the API key and its team access.") }
        guard let issue = response.data?.issue else { throw LockInError("Linear couldn't find this issue or you don't have access to it.") }
        return issue
    }

    /// `id` (an identifier such as ENG-1, or an issue's ID) with the first page of each connection.
    private func expanded(_ id: String) async throws -> Expanded {
        let connections = [("children", Self.fields), ("attachments", "url title"), ("relations", Self.relationFields),
                           ("inverseRelations", Self.relationFields)].map { Self.connection($0.0, $0.1) }.joined(separator: " ")
        return try await decode(Expanded.self, query: "query($id:String!,$after:String){issue(id:$id){\(Self.fields) \(connections)}}",
                                variables: ["id": id])
    }

    /// `first` and every later page of the issue's `field` connection.
    private func all<T: Decodable>(_ first: Page<T>, field: String, fields: String, id: String) async throws -> [T] {
        var result = first.nodes, page = first, seen = Set<String>()
        while page.pageInfo.hasNextPage {
            guard let next = page.pageInfo.endCursor, seen.insert(next).inserted else {
                throw LockInError("Linear returned an invalid pagination cursor.")
            }
            let query = "query($id:String!,$after:String){issue(id:$id){\(Self.connection(field, fields))}}"
            page = try await decode(OnlyField<Page<T>>.self, query: query, variables: ["id": id, "after": next]).value
            result += page.nodes
            guard result.count <= 2000 else { throw LockInError("This issue has too many relationships to import at once. Import a smaller subtree.") }
        }
        return result
    }

    public func fetch(_ input: String) async throws -> WorkImportResult {
        guard let identifier = Self.issueIdentifier(from: input) else { throw LockInError("Enter a Linear issue URL or issue identifier.") }
        let root = try await expanded(identifier)
        var queue = [root.issue], seen = Set<String>(), nodes: [String: WorkNode] = [:], edges: [WorkEdge] = []
        var fetched = [root.issue.id: root]
        while !queue.isEmpty {
            try Task.checkCancellation()
            let current = queue.removeFirst()
            guard seen.insert(current.id).inserted else { continue }
            guard seen.count <= 250 else { throw LockInError("This tree exceeds 250 issues. Import a smaller subtree.") }
            nodes[current.node.id] = current.node
            let expanded: Expanded
            if let known = fetched.removeValue(forKey: current.id) { expanded = known } else { expanded = try await self.expanded(current.id) }
            for child in try await all(expanded.children, field: "children", fields: Self.fields, id: current.id) {
                edges.append(WorkEdge(from: current.node.id, to: child.node.id, kind: .contains, source: .linear))
                queue.append(child)
            }
            for attachment in try await all(expanded.attachments, field: "attachments", fields: "url title", id: current.id) {
                guard let pr = PullRequestReference(url: attachment.url) else { continue }
                let id = pr.nodeID
                if nodes[id] == nil {
                    nodes[id] = WorkNode(id: id, kind: .pullRequest, title: attachment.title, url: pr.url,
                                         label: pr.key, status: WorkNode.PullRequestState.notFetched.rawValue)
                }
                edges.append(WorkEdge(from: current.node.id, to: id, kind: .implements, source: .linear))
            }
            let relations = try await all(expanded.relations, field: "relations", fields: Self.relationFields, id: current.id)
                + all(expanded.inverseRelations, field: "inverseRelations", fields: Self.relationFields, id: current.id)
            for relation in relations where relation.type == "blocks" {
                for issue in [relation.issue, relation.relatedIssue] where nodes[issue.node.id] == nil {
                    var node = issue.node; node.context = true; nodes[node.id] = node
                }
                edges.append(WorkEdge(from: relation.issue.node.id, to: relation.relatedIssue.node.id, kind: .depends, source: .linear))
            }
        }
        return WorkImportResult(nodes: nodes.values.sorted { $0.id < $1.id },
            snapshot: WorkImport(id: root.issue.node.id, url: root.issue.url, nodeIDs: nodes.keys.sorted(), edges: edges.uniqued(by: \.id)))
    }
}
