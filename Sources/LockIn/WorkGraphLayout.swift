import Foundation
import LockInCore

struct WorkGraphLayout {
    struct Group: Identifiable {
        var id: String
        var rect: CGRect
        var depth: Int
        /// Everything inside the region that the filter shows, drawn or folded away.
        var memberIDs: Set<String>
    }
    static let cardSize = CGSize(width: 230, height: 120)
    static let regionHeaderHeight: CGFloat = 92
    /// Distances in points.
    private enum Spacing {
        /// Around the canvas, and the top of anything not placed below something else.
        static let margin: CGFloat = 20
        /// From a region header to its contents.
        static let headerGap: CGFloat = 16
        /// Between cards stacked in one column.
        static let stackGap: CGFloat = 16
        /// Above a card below a dependency, so the connector has room to turn.
        static let dependencyClearance: CGFloat = 44
        /// Above a sibling block ordered after another; more for each level the source is nested.
        static let laneClearance: CGFloat = 28
        static let nestedLaneClearance: CGFloat = 24
        /// A region's contents, inset from its sides and above its bottom edge.
        static let regionInset: CGFloat = 20
        static let regionBottom: CGFloat = 24
        static let minRegionWidth: CGFloat = 270
        /// Between disconnected parts of the graph.
        static let componentGap: CGFloat = 40
    }
    private(set) var positions: [String: CGPoint] = [:]
    private(set) var frames: [String: CGRect] = [:]
    private(set) var groups: [Group] = []
    let representatives: [String: String]
    private(set) var size = CGSize(width: 400, height: 300)
    /// Connectors for the dependencies the layout was given, planned while choosing between candidate layouts.
    private(set) var routes: [String: WorkEdgeRoute] = [:]
    var routingSpace: RoutingSpace { RoutingSpace(frames: frames, representatives: representatives) }

    init(graph: WorkGraph, filter: WorkFilter, collapsed: Set<String>,
         hierarchy: WorkHierarchy? = nil, dependencies: [WorkEdge]? = nil) {
        let hierarchy = hierarchy ?? WorkHierarchy(graph: graph)
        let dependencies = dependencies ?? graph.sequencing.edges
        let structure = Structure(hierarchy: hierarchy, visibility: hierarchy.visibility(filter: filter, collapsed: collapsed),
                                  dependencies: dependencies)
        let candidates = [0.0, 1.0, 2.0, 4.0].map { Self(structure, laneFactor: $0) }
        func cost(_ layout: Self) -> Double {
            Self.score(layout.frames, edges: structure.dependencies, width: layout.size.width, height: layout.size.height)
        }
        let ranked = candidates.enumerated().map { (index: $0.offset, layout: $0.element, cost: cost($0.element)) }
            .sorted { ($0.cost, $0.index) < ($1.cost, $1.index) }
        var best = ranked[0].layout
        var bestCost = Double.infinity
        for candidate in ranked {
            let space = candidate.layout.routingSpace
            let routes = WorkEdgeRoute.plan(edges: dependencies, layout: space)
            let obstruction = WorkEdgeRoute.obstructionCost(routes: routes, edges: dependencies, layout: space)
            let combined = candidate.cost + Double(obstruction)
            if obstruction == 0 || combined < bestCost { best = candidate.layout; best.routes = routes; bestCost = combined }
            if obstruction == 0 { break }
        }
        self = best
    }

    /// What every candidate layout shares: the cards drawn, how they nest, and the edges between them.
    private struct Structure {
        let hierarchy: WorkHierarchy
        let representatives: [String: String]
        let shown: Set<String>
        let rendered: Set<String>
        /// Rendered cards with rendered contents, drawn as region headers.
        let regionIDs: Set<String>
        let children: [String: [String]]
        let roots: [String]
        /// Dependencies between rendered cards.
        let dependencies: [WorkEdge]
        /// `dependencies`, plus an edge from each region to its contents unless that would form a cycle.
        let edges: [WorkEdge]
        let depth: [String: Int]
        /// Deepest first, so contents are placed before the regions around them.
        let insideOut: [String]
        /// For each list of sibling blocks, the sibling owning every rendered card inside it.
        let owners: [[String]: [String: String]]

        init(hierarchy: WorkHierarchy, visibility: WorkHierarchy.Visibility, dependencies source: [WorkEdge]) {
            let parent = hierarchy.parent
            let representatives = visibility.representatives, rendered = visibility.rendered
            self.hierarchy = hierarchy
            self.representatives = representatives
            shown = visibility.shown
            self.rendered = rendered
            regionIDs = Set(parent.values).intersection(rendered)
            var children: [String: [String]] = [:]
            var roots: [String] = []
            for id in rendered.sorted() {
                if let owner = parent[id], rendered.contains(owner) { children[owner, default: []].append(id) }
                else { roots.append(id) }
            }
            self.children = children
            self.roots = roots
            dependencies = source.compactMap { edge in
                guard let from = representatives[edge.from], let to = representatives[edge.to], from != to else { return nil }
                return WorkEdge(from: from, to: to, kind: .depends, source: edge.source)
            }
            var edges = dependencies
            for id in rendered.sorted() {
                if let owner = parent[id], rendered.contains(owner), !WorkGraph.hasPath(from: id, to: owner, edges: edges) {
                    edges.append(WorkEdge(from: owner, to: id, kind: .contains, source: .linear))
                }
            }
            self.edges = edges
            var depth: [String: Int] = [:]
            func findDepth(_ id: String) -> Int {
                if let value = depth[id] { return value }
                let value = parent[id].flatMap { rendered.contains($0) ? findDepth($0) + 1 : nil } ?? 0
                depth[id] = value
                return value
            }
            for id in rendered { _ = findDepth(id) }
            self.depth = depth
            insideOut = rendered.sorted { (depth[$0]!, $0) > (depth[$1]!, $1) }
            var owners: [[String]: [String: String]] = [:]
            for members in [roots] + children.values {
                var owner: [String: String] = [:]
                for id in members {
                    owner[id] = id
                    for child in hierarchy.descendants(id) where rendered.contains(child) { owner[child] = id }
                }
                owners[members] = owner
            }
            self.owners = owners
        }

        func height(_ id: String) -> CGFloat { regionIDs.contains(id) ? WorkGraphLayout.regionHeaderHeight : WorkGraphLayout.cardSize.height }
    }

    /// One candidate layout. `laneFactor` sets how many lanes sibling blocks are scheduled into; zero leaves them unordered.
    private init(_ structure: Structure, laneFactor: Double) {
        representatives = structure.representatives
        let (edges, clearance) = Self.scheduleLanes(structure, laneFactor: laneFactor)
        let (y, bottom) = Self.assignRows(structure, edges: edges, clearance: clearance)
        frames = Self.packColumns(structure, y: y, bottom: bottom)
        var bounds = frames
        for id in structure.insideOut where structure.regionIDs.contains(id) {
            guard let header = frames[id] else { continue }
            let rect = CGRect(x: header.minX - 4, y: header.minY - 4,
                              width: header.width + 8, height: (bottom[id] ?? header.maxY) - header.minY + 8)
            bounds[id] = rect
            groups.append(Group(id: id, rect: rect, depth: structure.depth[id] ?? 0, memberIDs: structure.hierarchy.descendants(id).intersection(structure.shown)))
        }
        packComponents(structure.rendered, edges: edges, bounds: &bounds)
        groups.sort { ($0.depth, $0.id) < ($1.depth, $1.id) }
        positions = frames.mapValues { CGPoint(x: $0.midX, y: $0.midY) }
        size = CGSize(width: max(400, (bounds.values.map(\.maxX).max() ?? 0) + Spacing.margin), height: max(300, (bounds.values.map(\.maxY).max() ?? 0) + Spacing.margin))
    }

    /// Schedules sibling blocks into a few lanes, adding an ordering edge (with its clearance) only where it keeps the
    /// graph acyclic.
    private static func scheduleLanes(_ structure: Structure, laneFactor: Double) -> (edges: [WorkEdge], clearance: [String: CGFloat]) {
        let parent = structure.hierarchy.parent, rendered = structure.rendered
        var edges = structure.edges
        var clearance: [String: CGFloat] = [:]
        guard laneFactor > 0 else { return (edges, clearance) }
        for members in [structure.roots] + structure.children.keys.sorted().map({ structure.children[$0]! }) where members.count > 1 {
            let memberSet = Set(members)
            let owner = structure.owners[members]!
            var upstream: [String: Set<String>] = [:]
            for edge in structure.dependencies {
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
                        var padding: CGFloat = Spacing.laneClearance
                        var ancestor = parent[source]
                        while let current = ancestor, owner[current] == owner[source] {
                            padding += Spacing.nestedLaneClearance; ancestor = parent[current]
                        }
                        clearance[edge.id] = max(Spacing.dependencyClearance, padding)
                        edges.append(edge)
                    }
                }
                assigned[id] = lane; laneLast[lane] = id
                let estimate = CGFloat(structure.hierarchy.descendants(id).intersection(rendered).count + 1) * (cardSize.height + Spacing.dependencyClearance)
                finish[id] = max(earliest, laneEnds[lane]) + estimate
                laneEnds[lane] = finish[id]!
            }
        }
        return (edges, clearance)
    }

    /// Each card's top, below everything it follows, and each card's or region's bottom.
    private static func assignRows(_ structure: Structure, edges: [WorkEdge],
                                   clearance: [String: CGFloat]) -> (y: [String: CGFloat], bottom: [String: CGFloat]) {
        let incoming = Dictionary(grouping: edges, by: \.to)
        var y: [String: CGFloat] = [:]
        var remaining = structure.rendered
        while !remaining.isEmpty {
            var ready = remaining.filter { id in (incoming[id] ?? []).allSatisfy { !remaining.contains($0.from) } }
            // Collapsing interleaved stacks can create a cycle between aggregate regions.
            if ready.isEmpty { ready = [remaining.sorted()[0]] }
            for id in ready.sorted() {
                let top = (incoming[id] ?? []).compactMap { edge -> CGFloat? in
                    guard let sourceY = y[edge.from] else { return nil }
                    return sourceY + structure.height(edge.from) + (edge.kind == .contains ? Spacing.headerGap : clearance[edge.id] ?? Spacing.dependencyClearance)
                }.max() ?? Spacing.margin
                y[id] = top
            }
            remaining.subtract(ready)
        }
        // Put headers immediately above their contents while preserving outgoing dependency clearance.
        for id in structure.insideOut where structure.regionIDs.contains(id) && !(structure.children[id] ?? []).isEmpty {
            let limits = (structure.children[id] ?? []).compactMap { y[$0].map { $0 - regionHeaderHeight - Spacing.headerGap } }
                + edges.filter { $0.from == id && $0.kind == .depends }.compactMap { edge in y[edge.to].map { $0 - regionHeaderHeight - (clearance[edge.id] ?? Spacing.dependencyClearance) } }
            if let limit = limits.min() { y[id] = max(y[id] ?? Spacing.margin, limit) }
        }
        var bottom: [String: CGFloat] = [:]
        for id in structure.insideOut {
            let contentBottom = (structure.children[id] ?? []).compactMap { bottom[$0] }.max()
            bottom[id] = max((y[id] ?? Spacing.margin) + structure.height(id), contentBottom.map { $0 + Spacing.regionBottom } ?? 0)
        }
        return (y, bottom)
    }

    /// Packs each region's contents, then the roots, into columns near their neighbours.
    private static func packColumns(_ structure: Structure, y: [String: CGFloat], bottom: [String: CGFloat]) -> [String: CGRect] {
        let children = structure.children
        var previousX: [String: CGFloat] = [:]
        var best: [String: CGRect] = [:]
        var bestScore = Double.infinity
        // Repeated neighbor ordering reduces crossings without allowing a later sweep to worsen the layout.
        for _ in 0..<6 {
            var widths: [String: CGFloat] = [:]
            var offsets: [String: CGFloat] = [:]
            func pack(_ members: [String]) -> CGFloat {
                guard !members.isEmpty else { return 0 }
                let owner = structure.owners[members]!
                var neighbors: [String: [String]] = [:]
                for edge in structure.dependencies {
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
                    if y[$0] != y[$1] { return (y[$0] ?? Spacing.margin) < (y[$1] ?? Spacing.margin) }
                    let lhs = desired($0, placed: [:]) ?? 0, rhs = desired($1, placed: [:]) ?? 0
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }
                var columns: [[String]] = []
                var ends: [CGFloat] = []
                var columnWidths: [CGFloat] = []
                var placed: [String: CGFloat] = [:]
                for id in ordered {
                    let target = desired(id, placed: placed)
                    let available = columns.indices.filter { ends[$0] + Spacing.stackGap <= (y[id] ?? Spacing.margin) }
                    func center(_ index: Int) -> CGFloat {
                        columnWidths.prefix(index).reduce(0, +) + CGFloat(index) * WorkGeometry.columnGap + columnWidths[index] / 2
                    }
                    let chosen: Int
                    if let target {
                        chosen = available.min { abs(center($0) - target) < abs(center($1) - target) } ?? columns.count
                    } else { chosen = available.first ?? columns.count }
                    if chosen == columns.count {
                        columns.append([]); ends.append(0); columnWidths.append(widths[id] ?? cardSize.width)
                    }
                    columns[chosen].append(id)
                    ends[chosen] = bottom[id] ?? 0
                    columnWidths[chosen] = max(columnWidths[chosen], widths[id] ?? cardSize.width)
                    placed[id] = center(chosen)
                }
                var left: CGFloat = 0
                for (index, column) in columns.enumerated() {
                    for id in column { offsets[id] = left + (columnWidths[index] - (widths[id] ?? cardSize.width)) / 2 }
                    left += columnWidths[index] + WorkGeometry.columnGap
                }
                return left - WorkGeometry.columnGap
            }
            for id in structure.insideOut {
                let contentWidth = pack(children[id] ?? [])
                widths[id] = structure.regionIDs.contains(id) ? max(Spacing.minRegionWidth, contentWidth + 2 * Spacing.regionInset) : cardSize.width
            }
            let width = pack(structure.roots)
            var candidate: [String: CGRect] = [:]
            func place(_ id: String, origin: CGFloat) {
                let left = origin + (offsets[id] ?? 0)
                candidate[id] = CGRect(x: left, y: y[id] ?? Spacing.margin, width: widths[id]!, height: structure.height(id))
                for child in children[id] ?? [] { place(child, origin: left + Spacing.regionInset) }
            }
            for root in structure.roots { place(root, origin: Spacing.margin) }
            let score = Self.score(candidate, edges: structure.dependencies, width: width, height: bottom.values.max() ?? 0)
            if score < bestScore { best = candidate; bestScore = score }
            previousX = candidate.mapValues(\.midX)
        }
        return best
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
            let area = components.reduce(CGFloat.zero) { $0 + ($1.bounds.width + Spacing.componentGap) * ($1.bounds.height + Spacing.componentGap) }
            let rowWidth = max(components.map { $0.bounds.width }.max() ?? 0, sqrt(area * 1.5))
            var left = Spacing.margin, top = Spacing.margin, rowHeight: CGFloat = 0
            for component in components {
                if left > Spacing.margin && left + component.bounds.width > rowWidth + Spacing.margin {
                    left = Spacing.margin; top += rowHeight + Spacing.componentGap; rowHeight = 0
                }
                let dx = left - component.bounds.minX, dy = top - component.bounds.minY
                for id in component.ids {
                    frames[id] = frames[id]?.offsetBy(dx: dx, dy: dy)
                    bounds[id] = bounds[id]?.offsetBy(dx: dx, dy: dy)
                }
                for index in groups.indices where component.ids.contains(groups[index].id) {
                    groups[index].rect = groups[index].rect.offsetBy(dx: dx, dy: dy)
                }
                left += component.bounds.width + Spacing.componentGap
                rowHeight = max(rowHeight, component.bounds.height)
            }
        }
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
