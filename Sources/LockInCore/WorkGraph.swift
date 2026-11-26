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
    public var schema: String? = FileFormat.schemaBase + "work-graph-v1.schema.json"
    public var schemaVersion = 1
    public var nodes: [WorkNode] = []
    public var imports: [WorkImport] = []
    public var hiddenNodeIDs: Set<String> = []
    public init() {}
    enum CodingKeys: String, CodingKey {
        case schema = "$schema", schemaVersion = "schema_version", nodes, imports
        case hiddenNodeIDs = "hidden_node_ids"
    }

    public var visibleNodes: [WorkNode] { nodes.filter { !hiddenNodeIDs.contains($0.id) } }
    public var sourceEdges: [WorkEdge] {
        var seen = Set<String>()
        return imports.flatMap(\.edges).filter { seen.insert($0.id).inserted }
    }
    public var memberships: [WorkEdge] {
        let ids = Set(visibleNodes.map(\.id))
        return sourceEdges.filter { $0.kind != .depends && ids.contains($0.from) && ids.contains($0.to) }
    }
    /// Keep conflicting evidence for inspection, while the execution graph remains acyclic.
    public var sequencing: (edges: [WorkEdge], conflicts: [WorkEdge]) {
        let ids = Set(visibleNodes.map(\.id))
        let candidates = sourceEdges.filter {
            $0.kind == .depends && ids.contains($0.from) && ids.contains($0.to)
        }.sorted { ($0.source.priority, $0.id) < ($1.source.priority, $1.id) }
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
    public func blockers(of id: String) -> [WorkNode] {
        let upstream = Set(sequencing.edges.filter { $0.to == id }.map(\.from))
        return visibleNodes.filter { upstream.contains($0.id) && !$0.resolved }
    }
    public func descendants(of roots: Set<String>) -> Set<String> {
        var included = roots
        var pending = Array(roots)
        let children = Dictionary(grouping: memberships, by: \.from)
        while let id = pending.popLast() {
            for edge in children[id] ?? [] where included.insert(edge.to).inserted { pending.append(edge.to) }
        }
        return included
    }

    public func selectedAncestor(of id: String, among selected: Set<String>) -> String? {
        selected.sorted().first { $0 != id && Self.hasPath(from: $0, to: id, edges: memberships) }
    }

    public func topLevelIDs(_ ids: Set<String>) -> Set<String> {
        Set(ids.filter { id in
            !ids.contains { other in
                other != id && Self.hasPath(from: other, to: id, edges: memberships) &&
                    (!Self.hasPath(from: id, to: other, edges: memberships) || other < id)
            }
        })
    }

    public func focused(on selectedIDs: Set<String>) -> WorkGraph {
        var tree = selectedIDs
        var expanding = true
        while expanding {
            let before = tree
            for edge in memberships where tree.contains(edge.from) { tree.insert(edge.to) }
            expanding = before != tree
        }
        var included = tree
        let dependencies = sequencing.edges
        var changed = true
        while changed {
            let before = included
            for edge in dependencies where included.contains(edge.to) { included.insert(edge.from) }
            for edge in memberships {
                if included.contains(edge.to) { included.insert(edge.from) }
            }
            changed = before != included
        }
        var result = self
        result.nodes = visibleNodes.filter { included.contains($0.id) }
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
        var pending = [from], seen = Set<String>()
        while let next = pending.popLast() {
            if next == to { return true }
            guard seen.insert(next).inserted else { continue }
            pending += edges.filter { $0.from == next }.map(\.to)
        }
        return false
    }
    public static func migrating(_ tasks: [Todo]) -> WorkGraph {
        var graph = WorkGraph(), seen = Set<String>()
        let mapping = Dictionary(tasks.map { ($0.id, $0.workIdentity) }, uniquingKeysWith: { first, _ in first })
        for task in tasks where task.hasTitle {
            let id = mapping[task.id]!
            guard seen.insert(id).inserted else { continue }
            graph.nodes.append(WorkNode(id: id, kind: .local, title: task.title, url: task.link,
                                        resolved: task.completed))
        }
        return graph
    }
}

public enum WorkGraphStorage {
    public static func file(in directory: URL) -> URL { directory.appendingPathComponent("work-graph.json") }
    public static func load(from directory: URL) throws -> WorkGraph? {
        let url = file(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let graph = try FileFormat.decode(WorkGraph.self, from: Data(contentsOf: url), supported: 1)
        guard graph.schemaVersion == 1, Set(graph.nodes.map(\.id)).count == graph.nodes.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return graph
    }
    public static func save(_ graph: WorkGraph, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (FileFormat.encoder.encode(graph) + Data("\n".utf8)).write(to: file(in: directory), options: .atomic)
    }
}
