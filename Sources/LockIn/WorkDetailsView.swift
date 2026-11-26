import SwiftUI
import LockInCore

struct WorkDetailsView: View {
    @EnvironmentObject var store: Store
    let node: WorkNode
    let presentation: WorkPresentation
    let sessionIDs: Set<String>
    let relevantImports: [WorkImport]
    @Binding var selection: String?
    private var graph: WorkGraph { presentation.graph }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    WorkSourceBadge(kind: node.kind)
                    Text(node.label).font(.headline)
                    Spacer()
                    Button { selection = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.pointer(.plain)).accessibilityLabel("Close details")
                }
                Text(node.title).font(.title3)
                if node.kind == .local && sessionIDs.contains(node.id) {
                    LocalWorkEditor(node: node).id(node.id)
                }
                if let status = node.displayStatus {
                    Label(status, systemImage: node.resolved ? "checkmark.circle" : status == "Failing" ? "xmark.circle" : "circle")
                        .foregroundStyle(node.graphStatusColor)
                }
                if let url = URL(string: node.url), ["https", "http"].contains(url.scheme ?? "") {
                    Link("Open in \(node.kind == .linear ? "Linear" : node.kind == .pullRequest ? "GitHub" : "browser")", destination: url)
                }
                if sessionIDs.contains(node.id) {
                    Toggle("Done for this session", isOn: Binding(get: {
                        store.isSessionWorkDone(node.id)
                    }, set: { store.setSessionWorkDone(node.id, done: $0) }))
                    Text("Session completion does not change Linear or GitHub. PR prerequisites are satisfied when merged.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Remove from session") { store.removeWorkFromSession(node.id); selection = nil }
                } else {
                    Text("Source-owned work · shown through this session’s selected entries.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.workGraph.selectedAncestor(of: node.id, among: sessionIDs) == nil {
                        Button("Include in session") { store.selectWorkForSession(node) }
                    }
                }
                if node.context && node.kind == .linear && store.workGraph.selectedAncestor(of: node.id, among: sessionIDs) == nil {
                    Button("Import this issue’s tree") { store.importWork(node.url) }.disabled(store.workImporting)
                }
                Divider()
                Text("Dependencies").font(.headline)
                let upstream = presentation.incoming[node.id] ?? []
                if upstream.isEmpty { Text("No known prerequisites").foregroundStyle(.secondary) }
                ForEach(upstream) { edge in
                    relationship(edge, otherID: edge.from)
                }
                ForEach((presentation.outgoing[node.id] ?? [])) { edge in
                    Text("Before \(presentation.nodes[edge.to]?.label ?? edge.to)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !presentation.conflicts.filter({ $0.from == node.id || $0.to == node.id }).isEmpty {
                    Text("Conflicting source dependencies were excluded from sequencing. Review their source before relying on this order.")
                        .font(.caption).foregroundStyle(.orange)
                    ForEach(presentation.conflicts.filter { $0.from == node.id || $0.to == node.id }) { edge in
                        Text("\(edge.source.label): \(edge.from) → \(edge.to)").font(.caption)
                    }
                }
                Divider()
                Text("Related work").font(.headline)
                ForEach(presentation.memberships.filter { $0.from == node.id || $0.to == node.id }) { edge in
                    relationship(edge, otherID: edge.from == node.id ? edge.to : edge.from)
                }
                if let imported = relevantImports.first(where: { $0.nodeIDs.contains(node.id) }) {
                    Text("Refreshed \(imported.refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(imported.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }.padding(20)
        }
    }

    private func relationship(_ edge: WorkEdge, otherID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(presentation.nodes[otherID]?.label ?? otherID) { selection = otherID }
                    .buttonStyle(.pointer(.link))
                Spacer()

            }
            Text(edge.kind == .contains ? "Sub-issue relationship" : edge.kind == .implements ? "Linked PR · no implied order" : edge.source.label)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

}

private struct LocalWorkEditor: View {
    @EnvironmentObject var store: Store
    let node: WorkNode
    @State private var title = ""
    @State private var link = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title).textFieldStyle(.lockIn())
            TextField("Optional link", text: $link).textFieldStyle(.lockIn())
            LinkRequirementNote(link: link)
            Button("Save task") { store.renameSessionWork(node.id, title: title, link: link) }
                .disabled(!Todo().with(title: title, link: link).isValid)
        }.onAppear { title = node.title; link = node.url }
    }
}
