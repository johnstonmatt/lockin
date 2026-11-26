import Foundation
import LockInCore

struct WorkEdgeRoute {
    var points: [CGPoint]

    init(source: CGRect, target: CGRect, obstacles: [CGRect], occupied: [[CGPoint]] = []) {
        let start = CGPoint(x: source.midX, y: source.maxY)
        let end = CGPoint(x: target.midX, y: target.minY)
        let nearby = obstacles.filter { $0.maxY >= min(source.minY, target.minY) - 20 && $0.minY <= max(source.maxY, target.maxY) + 20 }
        var routes: [[CGPoint]] = []
        if end.y > start.y {
            let levels = Set([start.y + 14, end.y - WorkGeometry.arrowApproach, (start.y + end.y) / 2]
                + nearby.flatMap { [$0.minY - 12, $0.maxY + 12] })
            for y in levels.sorted() where y > start.y && y <= end.y - WorkGeometry.arrowApproach {
                routes.append([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
            }
        }
        var channels: Set<CGFloat> = [min(source.minX, target.minX) - 16, max(source.maxX, target.maxX) + 16]
        channels.formUnion([target.minX - WorkGeometry.arrowApproach, target.maxX + WorkGeometry.arrowApproach])
        for rect in nearby { channels.formUnion([rect.minX - 12, rect.maxX + 12]) }
        for route in occupied {
            for (a, b) in zip(route, route.dropFirst()) where a.x == b.x {
                channels.formUnion([a.x - WorkGeometry.laneSpacing, a.x + WorkGeometry.laneSpacing])
            }
        }
        for x in channels.sorted() {
            guard (x < source.minX || x > source.maxX), (x < target.minX || x > target.maxX) else { continue }
            for sourceOffset: CGFloat in [0, -20, 20] {
                for targetOffset: CGFloat in [0, -20, 20] {
                    let from = CGPoint(x: x < source.minX ? source.minX : source.maxX,
                                       y: source.midY + sourceOffset)
                    let to = CGPoint(x: x < target.minX ? target.minX : target.maxX,
                                     y: target.midY + targetOffset)
                    // Leave a straight approach beyond the rounded corner for the seven-point arrowhead.
                    guard abs(x - to.x) >= WorkGeometry.arrowApproach else { continue }
                    routes.append([from, CGPoint(x: x, y: from.y), CGPoint(x: x, y: to.y), to])
                }
            }
        }
        func score(_ points: [CGPoint]) -> CGFloat {
            var cost: CGFloat = points.first == start ? 0 : 24
                + abs(points[0].y - source.midY) + abs(points[points.count - 1].y - target.midY)
            if let endpoint = points.last {
                for route in occupied {
                    if let other = route.last, abs(endpoint.x - other.x) < 64, abs(endpoint.y - other.y) < 14 {
                        cost += 20_000
                    }
                }
            }
            for (a, b) in zip(points, points.dropFirst()) {
                cost += abs(a.x - b.x) + abs(a.y - b.y)
                cost += CGFloat(Self.collisions(a, b, nearby)) * 1_000_000
                for route in occupied {
                    for (c, d) in zip(route, route.dropFirst()) {
                        if Self.sharesLane(a, b, c, d) { cost += 10_000 }
                        if Self.crosses(a, b, c, d) { cost += 100_000 }
                    }
                }
            }
            return cost
        }
        points = routes.min { score($0) < score($1) } ?? [start, end]
        points = points.enumerated().filter { $0.offset == 0 || $0.element != points[$0.offset - 1] }.map(\.element)
    }

    static func plan(edges: [WorkEdge], layout: WorkGraphLayout) -> [String: WorkEdgeRoute] {
        let edges = edges.sorted { $0.id < $1.id }
        var best: [String: WorkEdgeRoute] = [:]
        var bestCost = CGFloat.infinity
        for initial in [edges, Array(edges.reversed())] {
            var result: [String: WorkEdgeRoute] = [:]
            // Each pass evaluates connectors against the complete set of occupied lanes.
            for pass in 0..<4 {
                let order = pass.isMultiple(of: 2) ? initial : Array(initial.reversed())
                var changed = false
                for edge in order {
                    guard let from = layout.representatives[edge.from], let to = layout.representatives[edge.to], from != to,
                          let source = layout.frames[from], let target = layout.frames[to] else { continue }
                    let occupied = edges.filter { $0.id != edge.id }.compactMap { result[$0.id]?.points }
                    let route = WorkEdgeRoute(source: source, target: target,
                                              obstacles: layout.obstacles(between: from, and: to), occupied: occupied)
                    if result[edge.id]?.points != route.points { changed = true }
                    result[edge.id] = route
                }
                if !changed { break }
            }
            let total = cost(result, edges: edges, layout: layout)
            if total < bestCost { bestCost = total; best = result }
        }
        // A shared source's ports must be considered together; changing one alone can retain a crossing.
        for _ in 0..<3 {
            var improved = false
            for (index, first) in edges.enumerated() {
                for second in edges.dropFirst(index + 1) {
                    guard layout.representatives[first.from] == layout.representatives[second.from],
                          var a = best[first.id], var b = best[second.id],
                          a.points.count == 4, b.points.count == 4,
                          a.points[0].x == b.points[0].x,
                          a.points[0].y == a.points[1].y, b.points[0].y == b.points[1].y else { continue }
                    let firstY = a.points[0].y, secondY = b.points[0].y
                    a.points[0].y = secondY; a.points[1].y = secondY
                    b.points[0].y = firstY; b.points[1].y = firstY
                    guard collisions(a, edge: first, layout: layout) == 0, collisions(b, edge: second, layout: layout) == 0 else { continue }
                    var candidate = best
                    candidate[first.id] = a; candidate[second.id] = b
                    let total = cost(candidate, edges: edges, layout: layout)
                    if total < bestCost { best = candidate; bestCost = total; improved = true }
                }
            }
            if !improved { break }
        }
        return best
    }

    static func obstructionCost(routes: [String: WorkEdgeRoute], edges: [WorkEdge], layout: WorkGraphLayout) -> CGFloat {
        let count = edges.reduce(0) { total, edge in total + (routes[edge.id].map { collisions($0, edge: edge, layout: layout) } ?? 0) }
        return CGFloat(count) * 100_000_000
    }

    private static func cost(_ routes: [String: WorkEdgeRoute], edges: [WorkEdge], layout: WorkGraphLayout) -> CGFloat {
        totalCost(edges.compactMap { routes[$0.id]?.points }) + obstructionCost(routes: routes, edges: edges, layout: layout)
    }

    /// Segment-card overlaps along `route`, against every card except the edge's own ends.
    private static func collisions(_ route: WorkEdgeRoute, edge: WorkEdge, layout: WorkGraphLayout) -> Int {
        let obstacles = layout.obstacles(between: layout.representatives[edge.from], and: layout.representatives[edge.to])
        return zip(route.points, route.points.dropFirst()).reduce(0) { $0 + collisions($1.0, $1.1, obstacles) }
    }

    /// Connectors keep five points clear of cards they pass.
    private static func collisions(_ a: CGPoint, _ b: CGPoint, _ obstacles: [CGRect]) -> Int {
        obstacles.filter { intersects(a, b, $0.insetBy(dx: -5, dy: -5)) }.count
    }

    private static func totalCost(_ routes: [[CGPoint]]) -> CGFloat {
        var cost: CGFloat = 0
        for (index, route) in routes.enumerated() {
            for (a, b) in zip(route, route.dropFirst()) {
                cost += abs(a.x - b.x) + abs(a.y - b.y)
                for other in routes.dropFirst(index + 1) {
                    for (c, d) in zip(other, other.dropFirst()) {
                        if crosses(a, b, c, d) { cost += 1_000_000 }
                        if sharesLane(a, b, c, d) { cost += 10_000 }
                    }
                }
            }
        }
        return cost
    }

    static func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        guard a != b, c != d, a != c, a != d, b != c, b != d else { return false }
        if a.x == b.x && c.y == d.y {
            return a.x >= min(c.x, d.x) && a.x <= max(c.x, d.x)
                && c.y >= min(a.y, b.y) && c.y <= max(a.y, b.y)
        }
        if a.y == b.y && c.x == d.x { return crosses(c, d, a, b) }
        return false
    }

    static func sharesLane(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        guard a != b, c != d else { return false }
        if a.x == b.x && c.x == d.x {
            return abs(a.x - c.x) < 9 && min(max(a.y, b.y), max(c.y, d.y)) > max(min(a.y, b.y), min(c.y, d.y))
        }
        if a.y == b.y && c.y == d.y {
            return abs(a.y - c.y) < 14 && min(max(a.x, b.x), max(c.x, d.x)) > max(min(a.x, b.x), min(c.x, d.x))
        }
        return false
    }

    static func intersects(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        if a.x == b.x {
            return a.x > rect.minX && a.x < rect.maxX && max(a.y, b.y) > rect.minY && min(a.y, b.y) < rect.maxY
        }
        return a.y > rect.minY && a.y < rect.maxY && max(a.x, b.x) > rect.minX && min(a.x, b.x) < rect.maxX
    }
}
