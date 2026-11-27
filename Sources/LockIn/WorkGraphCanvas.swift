import SwiftUI
import LockInCore

struct WorkGraphCanvas: View {
    let presentation: WorkPresentation
    @Binding var selection: String?
    let toggleCollapsed: (String) -> Void
    private var layout: WorkGraphLayout { presentation.layout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if presentation.graph.nodes.isEmpty {
                ContentUnavailableView("Choose this session’s work", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add a Linear issue to see its work tree, linked PRs, and the order they depend on each other."))
                    .frame(width: layout.size.width, height: layout.size.height)
            }
            ForEach(layout.groups) { group in
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(group.depth == 0 ? 0.35 : 0.6))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(presentation.sessionIDs.contains(group.id) ? 0.12 : 0.06)))
                    .frame(width: group.rect.width, height: group.rect.height)
                    .position(x: group.rect.midX, y: group.rect.midY)
                    .allowsHitTesting(false)
            }
            Canvas { context, _ in
                for edge in presentation.dependencies.sorted(by: { $0.id < $1.id }) {
                    guard let route = presentation.routes[edge.id] else { continue }
                    let highlighted = selection == edge.from || selection == edge.to
                    let color: Color = highlighted ? .accentColor : .secondary.opacity(0.5)
                    context.stroke(route.path, with: .color(color),
                                   style: StrokeStyle(lineWidth: highlighted ? 2 : 1.5, dash: edge.source == .branch ? [5, 4] : []))
                    if let arrow = route.arrowhead { context.stroke(arrow, with: .color(color), lineWidth: 1.5) }
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
            ForEach(presentation.graph.nodes.filter { layout.positions[$0.id] != nil }) { node in
                nodeView(node).position(layout.positions[node.id] ?? .zero)
            }
        }.frame(width: layout.size.width, height: layout.size.height)
    }

    @ViewBuilder
    private func nodeView(_ node: WorkNode) -> some View {
        if let summary = presentation.regionSummaries[node.id] {
            WorkRegionHeader(node: node, width: layout.frames[node.id]?.width ?? 300,
                             isContext: presentation.isContext(node.id), isSelected: selection == node.id,
                             collapsed: presentation.collapsed.contains(node.id), summary: summary,
                             select: { selection = node.id },
                             toggle: { toggleCollapsed(node.id) })
        } else {
            WorkNodeCard(node: node, isContext: presentation.isContext(node.id),
                         isSelected: selection == node.id, blockerCount: presentation.blockerCounts[node.id] ?? 0,
                         breadcrumb: presentation.containerLabels[node.id], select: { selection = node.id })
        }
    }
}
