import SwiftUI
import LockInCore

struct WorkNodeCard: View {
    let node: WorkNode
    let isContext: Bool
    let isSelected: Bool
    let blockerCount: Int
    let breadcrumb: String?
    let select: () -> Void
    @State private var hovered = false
    private var color: Color { node.graphStatusColor }
    private var cornerRadius: CGFloat { node.kind == .pullRequest ? 6 : 14 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        WorkSourceBadge(kind: node.kind)
                        Text(node.label)
                            .font(.system(size: 10, weight: .medium, design: node.kind == .pullRequest ? .monospaced : .default))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.trailing, 25)
                    Text(node.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        if let status = node.displayStatus {
                            Circle().fill(color).frame(width: 5, height: 5)
                            Text(status).foregroundStyle(color).help(node.statusExplanation)
                        }
                        if !node.resolved && blockerCount > 0 { Text("· \(blockerCount) blocker\(blockerCount == 1 ? "" : "s")") }
                        Spacer(minLength: 0)
                        if isContext { Text("Context").italic() }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let breadcrumb { Text("In \(breadcrumb)").font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
                .padding(14).frame(width: WorkGraphLayout.cardSize.width, height: WorkGraphLayout.cardSize.height)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            }.buttonStyle(.pointer(.plain))

        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(isSelected ? Color.accentColor : .primary.opacity(hovered ? 0.18 : 0.09)).allowsHitTesting(false))
        .overlay(alignment: .leading) {
            if node.kind == .linear {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 3, height: 30)
                    .padding(.leading, 1).allowsHitTesting(false)
            }
        }
        .opacity(isContext && !isSelected && !hovered ? 0.58 : 1)
        .shadow(color: .black.opacity(0.03), radius: 5, y: 2)
        .onHover { hovered = $0 }
    }
}


extension WorkNode {
    var graphStatusColor: Color {
        switch displayStatus {
        case "Merged": return Color(.sRGB, red: 130 / 255, green: 80 / 255, blue: 223 / 255, opacity: 1)
        case "Ready", "Done": return .green
        case "Failing": return .red
        case "Passing": return .blue
        case "Pending", "Closed": return .orange
        default: return .secondary
        }
    }
}

struct WorkRegionHeader: View {
    let node: WorkNode
    let width: CGFloat
    let isContext: Bool
    let isSelected: Bool
    let collapsed: Bool
    let prCount: Int
    let issueCount: Int
    let unresolvedCount: Int
    let select: () -> Void
    let toggle: () -> Void
    @State private var hovered = false
    private var summary: String {
        var parts: [String] = []
        if issueCount > 0 { parts.append("\(issueCount) sub-issue\(issueCount == 1 ? "" : "s")") }
        if prCount > 0 { parts.append("\(prCount) PR\(prCount == 1 ? "" : "s")") }
        parts.append("\(unresolvedCount) blocker\(unresolvedCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointer(.plain))
            .accessibilityLabel(collapsed ? "Expand \(node.label)" : "Collapse \(node.label)")
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        WorkSourceBadge(kind: .linear)
                        Text(node.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        if isContext { Text("Context").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(summary)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.pointer(.plain))

        }
        .padding(16)
        .frame(width: width, height: WorkGraphLayout.regionHeaderHeight, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .opacity(isContext && !hovered && !isSelected ? 0.58 : 1)
        .onHover { hovered = $0 }
    }
}


struct WorkSourceBadge: View {
    let kind: WorkNode.Kind
    var body: some View {
        HStack(spacing: 4) {
            if kind == .pullRequest {
                PullRequestGlyph().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 14).accessibilityHidden(true)
            } else {
                Image(systemName: kind == .linear ? "diamond.fill" : "checklist")
                    .font(.system(size: 9)).accessibilityHidden(true)
            }
            Text(kind == .pullRequest ? "PR" : kind == .linear ? "Linear" : "Task")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityLabel(kind == .pullRequest ? "GitHub pull request" : kind == .linear ? "Linear issue" : "Local task")
    }
}

private struct PullRequestGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 12, sy = rect.height / 14
        path.addEllipse(in: CGRect(x: 0, y: 0, width: 4 * sx, height: 4 * sy))
        path.addEllipse(in: CGRect(x: 0, y: 10 * sy, width: 4 * sx, height: 4 * sy))
        path.move(to: CGPoint(x: 2 * sx, y: 4 * sy))
        path.addLine(to: CGPoint(x: 2 * sx, y: 10 * sy))
        path.addEllipse(in: CGRect(x: 8 * sx, y: 10 * sy, width: 4 * sx, height: 4 * sy))
        path.move(to: CGPoint(x: 10 * sx, y: 10 * sy))
        path.addLine(to: CGPoint(x: 10 * sx, y: 5 * sy))
        path.addQuadCurve(to: CGPoint(x: 7 * sx, y: 2 * sy), control: CGPoint(x: 10 * sx, y: 2 * sy))
        path.move(to: CGPoint(x: 9 * sx, y: 0))
        path.addLine(to: CGPoint(x: 7 * sx, y: 2 * sy))
        path.addLine(to: CGPoint(x: 9 * sx, y: 4 * sy))
        return path
    }
}
