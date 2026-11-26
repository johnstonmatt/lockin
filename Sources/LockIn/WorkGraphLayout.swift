import Foundation
import LockInCore

struct WorkGraphLayout {
    struct Group: Identifiable {
        var id: String
        var rect: CGRect
        var depth: Int
        var memberIDs: Set<String>
    }
    static let cardSize = CGSize(width: 230, height: 120)
    static let regionHeaderHeight: CGFloat = 92
    var positions: [String: CGPoint] = [:]
    var frames: [String: CGRect] = [:]
    var groups: [Group] = []
    var representatives: [String: String] = [:]
    var size = CGSize(width: 400, height: 300)

    init(graph: WorkGraph, filter: WorkFilter, collapsed: Set<String>,
         hierarchy: WorkHierarchy? = nil, dependencies: [WorkEdge]? = nil) {
        let hierarchy = hierarchy ?? WorkHierarchy(graph: graph)
        let dependencies = dependencies ?? graph.sequencing.edges
        let candidates = [0.0, 1.0, 2.0, 4.0].map {
            Self(graph: graph, filter: filter, collapsed: collapsed, laneFactor: $0, hierarchy: hierarchy, dependencies: dependencies)
        }
        func cost(_ layout: Self) -> Double {
            Self.score(layout.frames, edges: layout.renderedEdges(dependencies), width: layout.size.width, height: layout.size.height)
        }
        let ranked = candidates.enumerated().map { (index: $0.offset, layout: $0.element, cost: cost($0.element)) }
            .sorted { ($0.cost, $0.index) < ($1.cost, $1.index) }
        var best = ranked[0].layout
        var bestCost = Double.infinity
        for candidate in ranked {
            let routes = WorkEdgeRoute.plan(edges: dependencies, layout: candidate.layout)
            let obstruction = WorkEdgeRoute.obstructionCost(routes: routes, edges: dependencies, layout: candidate.layout)
            if obstruction == 0 { self = candidate.layout; return }
            let combined = candidate.cost + Double(obstruction)
            if combined < bestCost { best = candidate.layout; bestCost = combined }
        }
        self = best
    }

    private init(graph: WorkGraph, filter: WorkFilter, collapsed: Set<String>, laneFactor: Double,
                 hierarchy: WorkHierarchy, dependencies sourceDependencies: [WorkEdge]) {
        let nodes = graph.visibleNodes
        let parent = hierarchy.parent
        let shown = Set(nodes.filter {
            filter.includes($0)
        }.map(\.id))
        let expandable = Set(parent.values).intersection(shown)
        for id in shown {
            var representative = id
            var ancestor = parent[id]
            while let current = ancestor {
                if shown.contains(current) && collapsed.contains(current) { representative = current }
                ancestor = parent[current]
            }
            representatives[id] = representative
        }
        let rendered = shown.filter { representatives[$0] == $0 }
        let regionIDs = expandable.intersection(rendered)
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in rendered.sorted() {
            if let owner = parent[id], rendered.contains(owner) { children[owner, default: []].append(id) }
            else { roots.append(id) }
        }

        var edges = renderedEdges(sourceDependencies)
        for id in rendered {
            if let owner = parent[id], rendered.contains(owner),
               !WorkGraph.hasPath(from: id, to: owner, edges: edges) {
                edges.append(WorkEdge(from: owner, to: id, kind: .contains, source: .linear))
            }
        }
        let dependencies = edges.filter { $0.kind == .depends }
        var clearance: [String: CGFloat] = [:]
        // Schedule sibling blocks into a small set of lanes; only add constraints that preserve the DAG.
        for members in [roots] + children.keys.sorted().map({ children[$0]! }) where members.count > 1 && laneFactor > 0 {
            let memberSet = Set(members)
            let owner = Self.blockOwners(members, hierarchy: hierarchy, rendered: rendered)
            var upstream: [String: Set<String>] = [:]
            for edge in dependencies {
                if let from = owner[edge.from], let to = owner[edge.to], from != to { upstream[to, default: []].insert(from) }
            }
            var remaining = memberSet, ordered: [String] = []
            while !remaining.isEmpty {
                let ready = remaining.filter { (upstream[$0] ?? []).isDisjoint(with: remaining) }.sorted()
                guard !ready.isEmpty else { break }
                ordered += ready; remaining.subtract(ready)
            }
            // Interleaved regions retain their global dependency order rather than forcing a block order.
            guard remaining.isEmpty else { continue }
            let laneCount = max(1, Int(ceil(sqrt(Double(members.count) * laneFactor))))
            var laneEnds = Array(repeating: CGFloat.zero, count: laneCount)
            var laneLast = Array<String?>(repeating: nil, count: laneCount)
            var assigned: [String: Int] = [:], finish: [String: CGFloat] = [:]
            for id in ordered {
                let predecessors = upstream[id] ?? []
                let earliest = predecessors.compactMap { finish[$0] }.max() ?? 0
                let preferred = Set(predecessors.compactMap { assigned[$0] })
                let lane = laneEnds.indices.min {
                    let a = max(earliest, laneEnds[$0]), b = max(earliest, laneEnds[$1])
                    if a != b { return a < b }
                    if preferred.contains($0) != preferred.contains($1) { return preferred.contains($0) }
                    return $0 < $1
                }!
                var before = predecessors
                if let previous = laneLast[lane] { before.insert(previous) }
                let sources = owner.keys.filter { before.contains(owner[$0]!) }.sorted()
                if sources.allSatisfy({ !WorkGraph.hasPath(from: id, to: $0, edges: edges) }) {
                    for source in sources {
                        let edge = WorkEdge(from: source, to: id, kind: .depends, source: .linear)
                        var padding: CGFloat = 28
                        var ancestor = parent[source]
                        while let current = ancestor, owner[current] == owner[source] {
                            padding += 24; ancestor = parent[current]
                        }
                        clearance[edge.id] = max(44, padding)
                        edges.append(edge)
                    }
                }
                assigned[id] = lane; laneLast[lane] = id
                let estimate = CGFloat(hierarchy.descendants(id).intersection(rendered).count + 1) * 164
                finish[id] = max(earliest, laneEnds[lane]) + estimate
                laneEnds[lane] = finish[id]!
            }
        }
        func height(_ id: String) -> CGFloat { regionIDs.contains(id) ? Self.regionHeaderHeight : Self.cardSize.height }
        let incoming = Dictionary(grouping: edges, by: \.to)
        var y: [String: CGFloat] = [:]
        var remaining = rendered
        while !remaining.isEmpty {
            var ready = remaining.filter { id in (incoming[id] ?? []).allSatisfy { !remaining.contains($0.from) } }
            // Collapsing interleaved stacks can create a cycle between aggregate regions.
            if ready.isEmpty { ready = [remaining.sorted()[0]] }
            for id in ready.sorted() {
                let top = (incoming[id] ?? []).compactMap { edge -> CGFloat? in
                    guard let sourceY = y[edge.from] else { return nil }
                    return sourceY + height(edge.from) + (edge.kind == .contains ? 16 : clearance[edge.id] ?? 44)
                }.max() ?? 20
                y[id] = top
            }
            remaining.subtract(ready)
        }
        var depth: [String: Int] = [:]
        func findDepth(_ id: String) -> Int {
            if let value = depth[id] { return value }
            let value = parent[id].flatMap { rendered.contains($0) ? findDepth($0) + 1 : nil } ?? 0
            depth[id] = value
            return value
        }
        for id in rendered { _ = findDepth(id) }
        let insideOut = rendered.sorted { (depth[$0]!, $0) > (depth[$1]!, $1) }
        // Put headers immediately above their contents while preserving outgoing dependency clearance.
        for id in insideOut where regionIDs.contains(id) && !(children[id] ?? []).isEmpty {
            let limits = (children[id] ?? []).compactMap { y[$0].map { $0 - Self.regionHeaderHeight - 16 } }
                + edges.filter { $0.from == id && $0.kind == .depends }.compactMap { edge in y[edge.to].map { $0 - Self.regionHeaderHeight - (clearance[edge.id] ?? 44) } }
            if let limit = limits.min() { y[id] = max(y[id] ?? 20, limit) }
        }
        var bottom: [String: CGFloat] = [:]
        for id in insideOut {
            let contentBottom = (children[id] ?? []).compactMap { bottom[$0] }.max()
            bottom[id] = max((y[id] ?? 20) + height(id), contentBottom.map { $0 + 24 } ?? 0)
        }
        var previousX: [String: CGFloat] = [:]
        var best: [String: CGRect] = [:]
        var bestScore = Double.infinity
        // Repeated neighbor ordering reduces crossings without allowing a later sweep to worsen the layout.
        for _ in 0..<6 {
            var widths: [String: CGFloat] = [:]
            var offsets: [String: CGFloat] = [:]
            func pack(_ members: [String]) -> CGFloat {
                guard !members.isEmpty else { return 0 }
                let owner = Self.blockOwners(members, hierarchy: hierarchy, rendered: rendered)
                var neighbors: [String: [String]] = [:]
                for edge in dependencies {
                    if let from = owner[edge.from], owner[edge.to] != from { neighbors[from, default: []].append(edge.to) }
                    if let to = owner[edge.to], owner[edge.from] != to { neighbors[to, default: []].append(edge.from) }
                }
                func desired(_ id: String, placed: [String: CGFloat]) -> CGFloat? {
                    let points = (neighbors[id] ?? []).compactMap { other -> CGFloat? in
                        if let peer = owner[other], let point = placed[peer] { return point }
                        return previousX[other]
                    }
                    return points.isEmpty ? nil : points.reduce(0, +) / CGFloat(points.count)
                }
                let ordered = members.sorted {
                    if y[$0] != y[$1] { return (y[$0] ?? 20) < (y[$1] ?? 20) }
                    let lhs = desired($0, placed: [:]) ?? 0, rhs = desired($1, placed: [:]) ?? 0
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }
                var columns: [[String]] = []
                var ends: [CGFloat] = []
                var columnWidths: [CGFloat] = []
                var placed: [String: CGFloat] = [:]
                for id in ordered {
                    let target = desired(id, placed: placed)
                    let available = columns.indices.filter { ends[$0] + 16 <= (y[id] ?? 20) }
                    func center(_ index: Int) -> CGFloat {
                        columnWidths.prefix(index).reduce(0, +) + CGFloat(index) * WorkGeometry.columnGap + columnWidths[index] / 2
                    }
                    let chosen: Int
                    if let target {
                        chosen = available.min { abs(center($0) - target) < abs(center($1) - target) } ?? columns.count
                    } else { chosen = available.first ?? columns.count }
                    if chosen == columns.count {
                        columns.append([]); ends.append(0); columnWidths.append(widths[id] ?? Self.cardSize.width)
                    }
                    columns[chosen].append(id)
                    ends[chosen] = bottom[id] ?? 0
                    columnWidths[chosen] = max(columnWidths[chosen], widths[id] ?? Self.cardSize.width)
                    placed[id] = center(chosen)
                }
                var left: CGFloat = 0
                for (index, column) in columns.enumerated() {
                    for id in column { offsets[id] = left + (columnWidths[index] - (widths[id] ?? Self.cardSize.width)) / 2 }
                    left += columnWidths[index] + WorkGeometry.columnGap
                }
                return left - WorkGeometry.columnGap
            }
            for id in insideOut {
                let contentWidth = pack(children[id] ?? [])
                widths[id] = regionIDs.contains(id) ? max(270, contentWidth + 40) : Self.cardSize.width
            }
            let width = pack(roots)
            var candidate: [String: CGRect] = [:]
            func place(_ id: String, origin: CGFloat) {
                let left = origin + (offsets[id] ?? 0)
                candidate[id] = CGRect(x: left, y: y[id] ?? 20, width: widths[id]!, height: height(id))
                for child in children[id] ?? [] { place(child, origin: left + 20) }
            }
            for root in roots { place(root, origin: 20) }
            let score = Self.score(candidate, edges: dependencies, width: width,
                                   height: bottom.values.max() ?? 0)
            if score < bestScore { best = candidate; bestScore = score }
            previousX = candidate.mapValues(\.midX)
        }
        frames = best
        var bounds = frames
        for id in insideOut where regionIDs.contains(id) {
            guard let header = frames[id] else { continue }
            let rect = CGRect(x: header.minX - 4, y: header.minY - 4,
                              width: header.width + 8, height: (bottom[id] ?? header.maxY) - header.minY + 8)
            bounds[id] = rect
            groups.append(Group(id: id, rect: rect, depth: depth[id] ?? 0, memberIDs: hierarchy.descendants(id)))
        }
        packComponents(rendered, edges: edges, bounds: &bounds)
        groups.sort { ($0.depth, $0.id) < ($1.depth, $1.id) }
        positions = frames.mapValues { CGPoint(x: $0.midX, y: $0.midY) }
        size = CGSize(width: max(400, (bounds.values.map(\.maxX).max() ?? 0) + 20), height: max(300, (bounds.values.map(\.maxY).max() ?? 0) + 20))
    }

    /// Places disconnected groups in rows, tallest first, so unrelated work doesn't stretch one axis.
    private mutating func packComponents(_ rendered: Set<String>, edges: [WorkEdge], bounds: inout [String: CGRect]) {
        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].insert(edge.to)
            adjacency[edge.to, default: []].insert(edge.from)
        }
        var unseen = rendered
        var components: [(ids: Set<String>, bounds: CGRect)] = []
        while let first = unseen.sorted().first {
            var pending = [first], ids = Set<String>()
            while let id = pending.popLast() {
                guard unseen.remove(id) != nil else { continue }
                ids.insert(id); pending += (adjacency[id] ?? []).sorted()
            }
            let rect = ids.compactMap { bounds[$0] }.reduce(CGRect.null) { $0.union($1) }
            components.append((ids, rect))
        }
        if components.count > 1 {
            components.sort {
                let lhs = $0.bounds.height, rhs = $1.bounds.height
                return lhs == rhs ? $0.ids.sorted()[0] < $1.ids.sorted()[0] : lhs > rhs
            }
            let area = components.reduce(CGFloat.zero) { $0 + ($1.bounds.width + 40) * ($1.bounds.height + 40) }
            let rowWidth = max(components.map { $0.bounds.width }.max() ?? 0, sqrt(area * 1.5))
            var left: CGFloat = 20, top: CGFloat = 20, rowHeight: CGFloat = 0
            for component in components {
                if left > 20 && left + component.bounds.width > rowWidth + 20 {
                    left = 20; top += rowHeight + 40; rowHeight = 0
                }
                let dx = left - component.bounds.minX, dy = top - component.bounds.minY
                for id in component.ids {
                    frames[id] = frames[id]?.offsetBy(dx: dx, dy: dy)
                    bounds[id] = bounds[id]?.offsetBy(dx: dx, dy: dy)
                }
                for index in groups.indices where component.ids.contains(groups[index].id) {
                    groups[index].rect = groups[index].rect.offsetBy(dx: dx, dy: dy)
                }
                left += component.bounds.width + 40
                rowHeight = max(rowHeight, component.bounds.height)
            }
        }
    }

    /// Source edges between the cards that represent their ends; edges folded into one collapsed region drop out.
    func renderedEdges(_ edges: [WorkEdge]) -> [WorkEdge] {
        edges.compactMap { edge in
            guard let from = representatives[edge.from], let to = representatives[edge.to], from != to else { return nil }
            return WorkEdge(from: from, to: to, kind: .depends, source: edge.source)
        }
    }

    /// Cards a connector between `from` and `to` must route around.
    func obstacles(between from: String?, and to: String?) -> [CGRect] {
        frames.filter { $0.key != from && $0.key != to }.map(\.value)
    }

    /// Maps each sibling block, and every rendered card inside it, to the sibling that owns it.
    private static func blockOwners(_ members: [String], hierarchy: WorkHierarchy, rendered: Set<String>) -> [String: String] {
        var owner: [String: String] = [:]
        for id in members {
            owner[id] = id
            for child in hierarchy.descendants(id) where rendered.contains(child) { owner[child] = id }
        }
        return owner
    }

    private static func score(_ frames: [String: CGRect], edges: [WorkEdge], width: CGFloat, height: CGFloat) -> Double {
        let segments = edges.compactMap { edge -> (CGPoint, CGPoint)? in
            guard let a = frames[edge.from], let b = frames[edge.to] else { return nil }
            return (CGPoint(x: a.midX, y: a.maxY), CGPoint(x: b.midX, y: b.minY))
        }
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var crossings = 0
        for i in segments.indices {
            for j in segments.indices where j > i {
                let (a, b) = segments[i], (c, d) = segments[j]
                if side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0 { crossings += 1 }
            }
        }
        let span = segments.reduce(CGFloat.zero) { $0 + abs($1.0.x - $1.1.x) }
        return Double(crossings) * 180 + Double(span) * 0.04
            + Double(max(width / 1.7, height)) + Double(sqrt(width * height)) * 0.1
    }
}
