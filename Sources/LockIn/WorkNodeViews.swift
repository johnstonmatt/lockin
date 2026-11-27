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
                        Text(status.rawValue).foregroundStyle(color).help(node.statusExplanation)
                    }
                    if !node.resolved && blockerCount > 0 { Text("· " + plural(blockerCount, "blocker")) }
                    Spacer(minLength: 0)
                    if isContext { Text("Context").italic() }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if let breadcrumb { Text("In \(breadcrumb)").font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
            .padding(14).frame(width: WorkGraphLayout.cardSize.width, height: WorkGraphLayout.cardSize.height)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }.buttonStyle(.pointer(.plain))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(isSelected ? Color.accentColor : .primary.opacity(hovered ? 0.18 : 0.09)).allowsHitTesting(false))
        .overlay(alignment: .leading) {
            if node.kind == .linear {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 3, height: 30)
                    .padding(.leading, 1).allowsHitTesting(false)
            }
        }
        .opacity(isContext && !isSelected && !hovered ? WorkGeometry.contextOpacity : 1)
        .shadow(color: .black.opacity(0.03), radius: 5, y: 2)
        .onHover { hovered = $0 }
    }
}

extension WorkNode {
    var graphStatusColor: Color {
        switch displayStatus {
        case .merged: return Color(.sRGB, red: 130 / 255, green: 80 / 255, blue: 223 / 255, opacity: 1)
        case .ready, .done: return .green
        case .failing: return .red
        case .passing: return .blue
        case .pending, .closed: return .orange
        case .open, .draft, nil: return .secondary
        }
    }
}

/// Expands or collapses a region, in the list and on the graph.
struct CollapseToggle: View {
    let collapsed: Bool
    let label: String
    var height: CGFloat = 24
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 11, weight: .semibold)).frame(width: 18, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointer(.plain))
        .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(label)")
    }
}

struct WorkRegionHeader: View {
    let node: WorkNode
    let width: CGFloat
    let isContext: Bool
    let isSelected: Bool
    let collapsed: Bool
    let summary: WorkPresentation.RegionSummary
    let select: () -> Void
    let toggle: () -> Void
    @State private var hovered = false
    private var summaryText: String {
        var parts: [String] = []
        if summary.issueCount > 0 { parts.append(plural(summary.issueCount, "sub-issue")) }
        if summary.prCount > 0 { parts.append(plural(summary.prCount, "PR")) }
        parts.append(plural(summary.unresolvedCount, "blocker"))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CollapseToggle(collapsed: collapsed, label: node.label, height: 22, toggle: toggle)
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        WorkSourceBadge(kind: .linear)
                        Text(node.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        if isContext { Text("Context").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(summaryText)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.pointer(.plain))
        }
        .padding(16)
        .frame(width: width, height: WorkGraphLayout.regionHeaderHeight, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .opacity(isContext && !hovered && !isSelected ? WorkGeometry.contextOpacity : 1)
        .onHover { hovered = $0 }
    }
}

/// "1 PR", "2 PRs".
func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

struct WorkSourceBadge: View {
    let kind: WorkNode.Kind
    var body: some View {
        HStack(spacing: 4) {
            switch kind {
            case .pullRequest:
                PullRequestGlyph().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 14).accessibilityHidden(true)
            case .linear:
                LinearGlyph().frame(width: 10, height: 10).accessibilityHidden(true)
            case .local:
                Image(systemName: "checklist").font(.system(size: 9)).accessibilityHidden(true)
            }
            Text(kind.badge).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityLabel(kind.accessibilityName)
    }
}

extension WorkNode.Kind {
    var badge: String {
        switch self {
        case .pullRequest: return "PR"
        case .linear: return "Linear"
        case .local: return "Task"
        }
    }
    var accessibilityName: String {
        switch self {
        case .pullRequest: return "GitHub pull request"
        case .linear: return "Linear issue"
        case .local: return "Local task"
        }
    }
    /// Where the node's link opens.
    var destination: String {
        switch self {
        case .pullRequest: return "GitHub"
        case .linear: return "Linear"
        case .local: return "browser"
        }
    }
}

/// Linear's mark: a disc cut by three diagonal gaps toward its lower left.
private struct LinearGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // On a 100-point disc, the filled bands between lines y - x = c.
        let bands: [(CGFloat, CGFloat)] = [(-100, 5.4), (15.9, 25.5), (36.9, 46.9), (60.3, 200)]
        var fill = Path()
        for (low, high) in bands {
            fill.addLines([CGPoint(x: -100, y: -100 + low), CGPoint(x: 200, y: 200 + low),
                           CGPoint(x: 200, y: 200 + high), CGPoint(x: -100, y: -100 + high)])
            fill.closeSubpath()
        }
        let disc = Path(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100))
        let side = min(rect.width, rect.height)
        return disc.intersection(fill).applying(
            CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2).scaledBy(x: side / 100, y: side / 100))
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
