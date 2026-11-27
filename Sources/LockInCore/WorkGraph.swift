import Foundation

public struct WorkNode: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, linear, pullRequest }
    public var id: String
    public var kind: Kind
    public var title: String
    public var url: String
    public var label: String
    public var status: String
    public var readiness: PullRequestReadiness?
    public var resolved: Bool
    public var attention: Bool
    public var context: Bool
    /// Spelled out, like `FileFormat`'s keys, so renaming a property can't change work-graph.json.
    enum CodingKeys: String, CodingKey {
        case id, kind, title, url, label, status, readiness, resolved, attention, context
    }
    public init(id: String, kind: Kind, title: String, url: String = "", label: String = "Task",
                status: String = "Open", resolved: Bool = false, attention: Bool = false, context: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.url = url; self.label = label
        self.status = status; self.resolved = resolved; self.attention = attention; self.context = context
    }
}

public struct WorkEdge: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case contains, implements, depends }
    public enum Source: String, Codable, Sendable {
        case linear, stack, branch
        public var label: String {
            switch self {
            case .linear: return "Linear"
            case .stack: return "GitHub stack"
            case .branch: return "Branch relationship"
            }
        }
        var priority: Int {
            switch self { case .stack: return 1; case .linear: return 2; case .branch: return 3 }
        }
    }
    /// Dependencies point from prerequisite to dependent; membership points from issue to member.
    public var from: String
    public var to: String
    public var kind: Kind
    public var source: Source
    enum CodingKeys: String, CodingKey { case from, to, kind, source }
    public var id: String { "\(kind.rawValue)|\(source.rawValue)|\(from)|\(to)" }
    public var pair: String { "\(from)|\(to)" }
    public init(from: String, to: String, kind: Kind, source: Source) {
        self.from = from; self.to = to; self.kind = kind; self.source = source
    }
}

public struct WorkImport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var nodeIDs: [String]
    public var edges: [WorkEdge]
    public var warnings: [String]
    public var refreshedAt: Date
    enum CodingKeys: String, CodingKey { case id, url, nodeIDs, edges, warnings, refreshedAt }
    public init(id: String, url: String, nodeIDs: [String], edges: [WorkEdge], warnings: [String] = [], refreshedAt: Date = Date()) {
        self.id = id; self.url = url; self.nodeIDs = nodeIDs; self.edges = edges
        self.warnings = warnings; self.refreshedAt = refreshedAt
    }
}

public struct WorkImportResult: Sendable {
    public var nodes: [WorkNode]
    public var snapshot: WorkImport
    public init(nodes: [WorkNode], snapshot: WorkImport) { self.nodes = nodes; self.snapshot = snapshot }
}

public struct WorkGraph: Codable, Equatable, Sendable {
    public var schema: String? = FileFormat.schemaBase + "work-graph-v\(FileFormat.workGraphVersion).schema.json"
    public var schemaVersion = FileFormat.workGraphVersion
    public var nodes: [WorkNode] = []
    public var imports: [WorkImport] = []
    public init() {}
    enum CodingKeys: String, CodingKey {
        case schema = "$schema", schemaVersion = "schema_version", nodes, imports
    }

    public var sourceEdges: [WorkEdge] { imports.flatMap(\.edges).uniqued(by: \.id) }
    /// Source edges between nodes in the graph. A focused graph keeps every import, so edges can name nodes it left out.
    private var nodeEdges: [WorkEdge] {
        let ids = Set(nodes.map(\.id))
        return sourceEdges.filter { ids.contains($0.from) && ids.contains($0.to) }
    }
    public var memberships: [WorkEdge] { nodeEdges.filter { $0.kind != .depends } }
    /// Keep conflicting evidence for inspection, while the execution graph remains acyclic.
    public var sequencing: (edges: [WorkEdge], conflicts: [WorkEdge]) {
        let candidates = nodeEdges.filter { $0.kind == .depends }.sorted { ($0.source.priority, $0.id) < ($1.source.priority, $1.id) }
        var accepted: [WorkEdge] = [], conflicts: [WorkEdge] = []
        var pairs = Set<String>()
        for edge in candidates {
            guard !pairs.contains(edge.pair) else { continue }
            if Self.hasPath(from: edge.to, to: edge.from, edges: accepted) {
                conflicts.append(edge)
            } else {
                accepted.append(edge); pairs.insert(edge.pair)
            }
        }
        return (accepted, conflicts)
    }
    /// The `dependencies` whose prerequisite isn't resolved yet: what still holds up the work each one leads to.
    public func blocking(_ dependencies: [WorkEdge]) -> [WorkEdge] {
        let resolved = Set(nodes.filter(\.resolved).map(\.id))
        return dependencies.filter { !resolved.contains($0.from) }
    }
    public func descendants(of roots: Set<String>) -> Set<String> {
        Self.closure(of: roots, along: Self.adjacency(memberships, forward: true))
    }

    public func selectedAncestor(of id: String, among selected: Set<String>) -> String? {
        let ancestors = Self.closure(of: [id], along: Self.adjacency(memberships, forward: false))
        return selected.sorted().first { $0 != id && ancestors.contains($0) }
    }

    /// Entries contained by another selected entry are dropped; of two entries containing each other, the smaller ID stays.
    public func topLevelIDs(_ ids: Set<String>) -> Set<String> {
        let children = Self.adjacency(memberships, forward: true)
        let reach = Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.closure(of: [$0], along: children)) })
        return ids.filter { id in
            !ids.contains { other in
                other != id && reach[other]!.contains(id) && (!reach[id]!.contains(other) || other < id)
            }
        }
    }

    /// The selected entries' trees, plus every prerequisite and container needed to place them.
    public func focused(on selectedIDs: Set<String>) -> WorkGraph {
        let upstream = Self.adjacency(sequencing.edges + memberships, forward: false)
        let included = Self.closure(of: descendants(of: selectedIDs), along: upstream)
        var result = self
        result.nodes = nodes.filter { included.contains($0.id) }
        return result
    }

    public mutating func merge(_ result: WorkImportResult) {
        for node in result.nodes {
            if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                var updated = node
                // A context-only reference must not downgrade a fully imported node.
                if node.context && !nodes[index].context { updated.context = false }
                nodes[index] = updated
            } else { nodes.append(node) }
        }
        imports.removeAll { $0.id == result.snapshot.id }
        imports.append(result.snapshot)
    }
    public static func hasPath(from: String, to: String, edges: [WorkEdge]) -> Bool {
        closure(of: [from], along: adjacency(edges, forward: true)).contains(to)
    }

    private static func adjacency(_ edges: [WorkEdge], forward: Bool) -> [String: [String]] {
        Dictionary(grouping: edges, by: { forward ? $0.from : $0.to }).mapValues { $0.map { forward ? $0.to : $0.from } }
    }

    private static func closure(of start: Set<String>, along adjacency: [String: [String]]) -> Set<String> {
        var reached = start, pending = Array(start)
        while let id = pending.popLast() {
            for next in adjacency[id] ?? [] where reached.insert(next).inserted { pending.append(next) }
        }
        return reached
    }
    public static func migrating(_ tasks: [Todo]) -> WorkGraph {
        var graph = WorkGraph()
        graph.nodes = tasks.filter(\.hasTitle).uniqued(by: \.workIdentity).map(WorkNode.init(localTask:))
        return graph
    }
}

extension Sequence {
    /// The first element for each key, in order.
    public func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
