import SwiftUI
import LockInCore

struct WorkListView: View {
    let presentation: WorkPresentation
    let sessionIDs: Set<String>
    let completedIDs: Set<String>
    let collapsed: Set<String>
    @Binding var selection: String?
    let toggleCollapsed: (String) -> Void
    let setDone: (String, Bool) -> Void
    private var graph: WorkGraph { presentation.graph }
    private var listRows: [WorkListLayout.Row] { presentation.rows }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if listRows.isEmpty {
                    ContentUnavailableView("No work to show", systemImage: "list.bullet",
                        description: Text(graph.nodes.isEmpty ? "Add work to choose what to focus on this session." : "Choose another filter to see this session’s work."))
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                }
                ForEach(listRows) { row in
                    listRow(row)
                    Divider()
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listRow(_ row: WorkListLayout.Row) -> some View {
        let node = row.node
        let context = !graph.descendants(of: sessionIDs).contains(node.id)
        return HStack(spacing: 12) {
            if row.descendantCount > 0 {
                Button { toggleCollapsed(node.id) } label: {
                    Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }.buttonStyle(.pointer(.plain))
                    .accessibilityLabel("\(collapsed.contains(node.id) ? "Expand" : "Collapse") \(node.label)")
            } else {
                Color.clear.frame(width: 18, height: 24).accessibilityHidden(true)
            }
            if sessionIDs.contains(node.id) {
                let done = completedIDs.contains(node.id)
                Button { setDone(node.id, !done) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.green : .secondary)
                }.buttonStyle(.pointer(.plain))
                    .accessibilityLabel("\(done ? "Mark not done" : "Mark done"): \(node.title)")
                    .help("Completion for this session")
            } else {
                Color.clear.frame(width: 14).accessibilityHidden(true)
            }
            Button { selection = node.id } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            WorkSourceBadge(kind: node.kind)
                            Text(node.label).font(.caption).foregroundStyle(.secondary)
                            if context { Text("Context").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(node.title).font(.body).lineLimit(2)
                        if collapsed.contains(node.id) && row.descendantCount > 0 {
                            Text("\(row.descendantCount) hidden item\(row.descendantCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let breadcrumb = row.breadcrumb {
                            Text(breadcrumb).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let status = node.displayStatus {
                        Text(status.rawValue).font(.caption).foregroundStyle(node.graphStatusColor)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.pointer(.plain))
        }
        .padding(12)
        .background(selection == node.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .opacity(context && selection != node.id ? 0.58 : 1)
        .padding(.leading, CGFloat(row.depth) * 24)
    }

}
