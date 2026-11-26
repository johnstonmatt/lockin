import SwiftUI
import LockInCore

struct WorkGraphCanvas: View {
    let presentation: WorkPresentation
    let sessionIDs: Set<String>
    let collapsed: Set<String>
    @Binding var selection: String?
    let toggleCollapsed: (String) -> Void
    private var graph: WorkGraph { presentation.graph }
    private var layout: WorkGraphLayout { presentation.layout }
    private var routes: [String: WorkEdgeRoute] { presentation.routes }

    var body: some View {
        let layout = layout
        let graph = graph
        let sequencing = presentation.dependencies
        let counts = presentation.blockerCounts
        return ZStack(alignment: .topLeading) {
            if graph.nodes.isEmpty {
                ContentUnavailableView("Choose this session’s work", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add a Linear issue to see its work tree, linked PRs, and the order they depend on each other."))
                    .frame(width: layout.size.width, height: layout.size.height)
            }
            ForEach(layout.groups) { group in
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(group.depth == 0 ? 0.35 : 0.6))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(sessionIDs.contains(group.id) ? 0.12 : 0.06)))
                    .frame(width: group.rect.width, height: group.rect.height)
                    .position(x: group.rect.midX, y: group.rect.midY)
                    .allowsHitTesting(false)
            }
            Canvas { context, _ in
                for edge in sequencing.sorted(by: { $0.id < $1.id }) {
                    guard let route = routes[edge.id] else { continue }
                    let line = roundedRoute(route.points)
                    let highlighted = selection == edge.from || selection == edge.to
                    let color: Color = highlighted ? .accentColor : .secondary.opacity(0.5)
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: highlighted ? 2 : 1.5,
                        dash: edge.source == .branch ? [5, 4] : []))
                    guard let end = route.points.last, route.points.count > 1 else { continue }
                    let before = route.points[route.points.count - 2]
                    let length = hypot(end.x - before.x, end.y - before.y)
                    guard length > 0 else { continue }
                    let dx = (end.x - before.x) / length, dy = (end.y - before.y) / length
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: end.x - dx * WorkGeometry.arrowLength - dy * WorkGeometry.arrowHalfWidth, y: end.y - dy * WorkGeometry.arrowLength + dx * WorkGeometry.arrowHalfWidth))
                    arrow.addLine(to: end)
                    arrow.addLine(to: CGPoint(x: end.x - dx * WorkGeometry.arrowLength + dy * WorkGeometry.arrowHalfWidth, y: end.y - dy * WorkGeometry.arrowLength - dx * WorkGeometry.arrowHalfWidth))
                    context.stroke(arrow, with: .color(color), lineWidth: 1.5)
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
            ForEach(graph.nodes.filter { layout.positions[$0.id] != nil }) { node in
                nodeView(node, layout: layout, blockerCount: counts[node.id] ?? 0)
                    .position(layout.positions[node.id] ?? .zero)
            }
        }.frame(width: layout.size.width, height: layout.size.height)
    }

    private func roundedRoute(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let start = points.first else { return path }
        path.move(to: start)
        for index in 1..<points.count {
            let corner = points[index]
            guard index + 1 < points.count else { path.addLine(to: corner); break }
            let before = points[index - 1], after = points[index + 1]
            let incoming = hypot(corner.x - before.x, corner.y - before.y)
            let outgoing = hypot(after.x - corner.x, after.y - corner.y)
            let radius = min(WorkGeometry.cornerRadius, incoming / 2, outgoing / 2)
            guard radius > 0 else { continue }
            let entry = CGPoint(x: corner.x + (before.x - corner.x) * radius / incoming,
                                y: corner.y + (before.y - corner.y) * radius / incoming)
            let exit = CGPoint(x: corner.x + (after.x - corner.x) * radius / outgoing,
                               y: corner.y + (after.y - corner.y) * radius / outgoing)
            path.addLine(to: entry)
            path.addQuadCurve(to: exit, control: corner)
        }
        return path
    }

    @ViewBuilder
    private func nodeView(_ node: WorkNode, layout: WorkGraphLayout, blockerCount: Int) -> some View {
        if let region = layout.groups.first(where: { $0.id == node.id }) {
            let members = graph.nodes.filter { region.memberIDs.contains($0.id) }
            let prerequisites = Set(presentation.dependencies.filter {
                region.memberIDs.contains($0.to) || $0.to == node.id
            }.map(\.from))
            let unresolved = graph.nodes.filter { prerequisites.contains($0.id) && !$0.resolved }.count
            WorkRegionHeader(node: node, width: layout.frames[node.id]?.width ?? 300,
                             isContext: !graph.descendants(of: sessionIDs).contains(node.id), isSelected: selection == node.id,
                             collapsed: collapsed.contains(node.id),
                             prCount: members.filter { $0.kind == .pullRequest }.count,
                             issueCount: members.filter { $0.kind == .linear }.count,
                             unresolvedCount: unresolved,
                             select: { selection = node.id },
                             toggle: { toggleCollapsed(node.id) })
        } else {
            WorkNodeCard(node: node, isContext: !graph.descendants(of: sessionIDs).contains(node.id),
                         isSelected: selection == node.id, blockerCount: blockerCount,
                         breadcrumb: parentLabel(for: node), select: { selection = node.id })
        }
    }

    private func parentLabel(for node: WorkNode) -> String? {
        guard let edge = presentation.memberships.first(where: { $0.to == node.id && $0.kind == .contains }) else { return nil }
        return presentation.nodes[edge.from]?.label
    }

}
