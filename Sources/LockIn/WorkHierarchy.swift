import Foundation
import LockInCore

struct WorkHierarchy {
    let nodes: [String: WorkNode]
    let parent: [String: String]
    let children: [String: [String]]

    init(graph: WorkGraph) {
        let nodes = Dictionary(uniqueKeysWithValues: graph.visibleNodes.map { ($0.id, $0) })
        var parent: [String: String] = [:]
        // Shared PRs have one stable owner; malformed membership cycles cannot form a tree.
        for edge in graph.memberships.sorted(by: { $0.id < $1.id })
            where nodes[edge.from]?.kind == .linear && nodes[edge.to] != nil && parent[edge.to] == nil {
            var ancestor: String? = edge.from
            var cyclic = false
            while let id = ancestor {
                if id == edge.to { cyclic = true; break }
                ancestor = parent[id]
            }
            if !cyclic { parent[edge.to] = edge.from }
        }
        self.nodes = nodes
        self.parent = parent
        children = Dictionary(grouping: parent.keys, by: { parent[$0]! })
    }

    func descendants(_ id: String) -> Set<String> {
        var result = Set<String>(), pending = children[id] ?? []
        while let next = pending.popLast() {
            if result.insert(next).inserted { pending += children[next] ?? [] }
        }
        return result
    }

    func breadcrumb(for id: String) -> String? {
        var labels: [String] = []
        var ancestor = parent[id]
        while let current = ancestor {
            if let node = nodes[current] { labels.append(node.label.isEmpty ? node.title : node.label) }
            ancestor = parent[current]
        }
        return labels.isEmpty ? nil : labels.reversed().joined(separator: " / ")
    }
}

struct WorkListLayout {
    struct Row: Identifiable {
        var node: WorkNode
        var depth: Int
        var descendantCount: Int
        var breadcrumb: String?
        var id: String { node.id }
    }
    var rows: [Row] = []

    init(graph: WorkGraph, filter: WorkFilter, collapsed: Set<String>, hierarchy: WorkHierarchy? = nil) {
        let hierarchy = hierarchy ?? WorkHierarchy(graph: graph)
        let shown = Set(hierarchy.nodes.values.filter {
            filter.includes($0)
        }.map(\.id))
        func sorted(_ ids: [String]) -> [String] {
            ids.sorted {
                let lhs = hierarchy.nodes[$0]!, rhs = hierarchy.nodes[$1]!
                let comparison = (lhs.label + " " + lhs.title).localizedStandardCompare(rhs.label + " " + rhs.title)
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }
        }
        func append(_ id: String, depth: Int) {
            guard let node = hierarchy.nodes[id] else { return }
            let count = hierarchy.descendants(id).intersection(shown).count
            rows.append(Row(node: node, depth: depth, descendantCount: count,
                            breadcrumb: filter == .prs ? hierarchy.breadcrumb(for: id) : nil))
            guard !collapsed.contains(id), filter != .prs else { return }
            for child in sorted((hierarchy.children[id] ?? []).filter { shown.contains($0) }) {
                append(child, depth: depth + 1)
            }
        }
        let roots = shown.filter { hierarchy.parent[$0].map { !shown.contains($0) } ?? true }
        for id in sorted(Array(roots)) { append(id, depth: 0) }
    }
}
