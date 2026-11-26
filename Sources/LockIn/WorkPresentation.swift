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
    struct RegionSummary: Equatable {
        var issueCount = 0
        var prCount = 0
        var unresolvedCount = 0
    }

    let graph: WorkGraph
    let sessionIDs: Set<String>
    let collapsed: Set<String>
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
    /// Sub-issues name the issue containing them; linked PRs carry no container label.
    let containerLabels: [String: String]
    let regionSummaries: [String: RegionSummary]
    private let sessionWork: Set<String>

    init(graph: WorkGraph, sessionIDs: Set<String> = [], filter: WorkFilter, collapsed: Set<String>) {
        self.graph = graph
        self.sessionIDs = sessionIDs
        self.collapsed = collapsed
        sessionWork = graph.descendants(of: sessionIDs)
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        self.nodes = nodes
        let sequencing = graph.sequencing
        dependencies = sequencing.edges
        conflicts = sequencing.conflicts
        memberships = graph.memberships
        incoming = Dictionary(grouping: dependencies, by: \.to)
        outgoing = Dictionary(grouping: dependencies, by: \.from)
        let unresolved = dependencies.filter { nodes[$0.from]?.resolved != true }
        blockerCounts = Dictionary(grouping: unresolved, by: \.to).mapValues(\.count)
        let hierarchy = WorkHierarchy(graph: graph)
        rows = WorkListLayout(graph: graph, filter: filter, collapsed: collapsed, hierarchy: hierarchy).rows
        layout = WorkGraphLayout(graph: graph, filter: filter, collapsed: collapsed,
                                 hierarchy: hierarchy, dependencies: dependencies)
        routes = WorkEdgeRoute.plan(edges: dependencies, layout: layout)
        var containerLabels: [String: String] = [:]
        for edge in memberships where edge.kind == .contains && containerLabels[edge.to] == nil {
            if let label = nodes[edge.from]?.label { containerLabels[edge.to] = label }
        }
        self.containerLabels = containerLabels
        regionSummaries = Dictionary(uniqueKeysWithValues: layout.groups.map { region in
            let members = region.memberIDs.compactMap { nodes[$0] }
            let prerequisites = Set(unresolved.filter { region.memberIDs.contains($0.to) || $0.to == region.id }.map(\.from))
            return (region.id, RegionSummary(issueCount: members.filter { $0.kind == .linear }.count,
                                             prCount: members.filter { $0.kind == .pullRequest }.count,
                                             unresolvedCount: prerequisites.count))
        })
    }

    /// Context work is shown only to place the session's own work: a prerequisite or a containing issue.
    func isContext(_ id: String) -> Bool { !sessionWork.contains(id) }
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
