import Foundation
import LockInCore

enum WorkFilter: String, CaseIterable {
    case all = "All work", issues = "Issues", prs = "PRs"

    func includes(_ node: WorkNode) -> Bool {
        switch self {
        case .all: return true
        case .issues: return node.kind != .pullRequest
        case .prs: return node.kind == .pullRequest
        }
    }
}

/// One immutable projection keeps list rows, graph geometry, and connectors on the same revision.
struct WorkPresentation {
    let graph: WorkGraph
    let nodes: [String: WorkNode]
    let dependencies: [WorkEdge]
    let conflicts: [WorkEdge]
    let memberships: [WorkEdge]
    let incoming: [String: [WorkEdge]]
    let outgoing: [String: [WorkEdge]]
    let blockerCounts: [String: Int]
    let rows: [WorkListLayout.Row]
    let layout: WorkGraphLayout
    let routes: [String: WorkEdgeRoute]

    init(graph: WorkGraph, filter: WorkFilter, collapsed: Set<String>) {
        self.graph = graph
        nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let sequencing = graph.sequencing
        dependencies = sequencing.edges
        conflicts = sequencing.conflicts
        memberships = graph.memberships
        incoming = Dictionary(grouping: dependencies, by: \.to)
        outgoing = Dictionary(grouping: dependencies, by: \.from)
        let resolved = Set(graph.nodes.filter(\.resolved).map(\.id))
        blockerCounts = Dictionary(grouping: dependencies.filter { !resolved.contains($0.from) }, by: \.to).mapValues(\.count)
        let hierarchy = WorkHierarchy(graph: graph)
        rows = WorkListLayout(graph: graph, filter: filter, collapsed: collapsed, hierarchy: hierarchy).rows
        layout = WorkGraphLayout(graph: graph, filter: filter, collapsed: collapsed,
                                 hierarchy: hierarchy, dependencies: dependencies)
        routes = WorkEdgeRoute.plan(edges: dependencies, layout: layout)
    }
}

/// Routing and column packing share the space needed for rounded corners and separate arrowheads.
enum WorkGeometry {
    static let cornerRadius: CGFloat = 8
    static let arrowLength: CGFloat = 7
    static let arrowHalfWidth: CGFloat = 4
    static let arrowApproach: CGFloat = 18
    static let laneSpacing: CGFloat = 10
    static let columnGap: CGFloat = 48
}
