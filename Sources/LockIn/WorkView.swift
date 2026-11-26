import SwiftUI
import LockInCore

enum WorkViewMode: String, CaseIterable {
    case graph = "Graph", list = "List"
}

struct WorkView: View {
    @AppStorage("workViewMode") private var mode: WorkViewMode = .graph
    @EnvironmentObject var store: Store
    @State private var selection: String?
    @State private var filter: WorkFilter = .all
    @State private var collapsed = Set<String>()
    @State private var showAdd = false
    @State private var showConnections = false
    @State private var fitRevision = 0
    @State private var presentation = WorkPresentation(graph: WorkGraph(), filter: .all, collapsed: [])

    private var graph: WorkGraph { store.sessionGraph }
    private var selected: WorkNode? { graph.nodes.first { $0.id == selection } }
    private var sessionIDs: Set<String> { store.sessionWorkIDs }
    private var relevantImports: [WorkImport] {
        store.workGraph.imports.filter { !sessionIDs.isDisjoint(with: $0.nodeIDs) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if mode == .graph {
                    GraphViewport(contentSize: presentation.layout.size, fitRevision: fitRevision) {
                        WorkGraphCanvas(presentation: presentation, sessionIDs: sessionIDs, collapsed: collapsed,
                                        selection: $selection, toggleCollapsed: toggleCollapsed)
                    }
                } else {
                    WorkListView(presentation: presentation, sessionIDs: sessionIDs,
                                 completedIDs: Set(store.graphSessionTasks.filter(\.completed).map(\.workIdentity)),
                                 collapsed: collapsed, selection: $selection, toggleCollapsed: toggleCollapsed,
                                 setDone: { store.setSessionWorkDone($0, done: $1) })
                }
                if let node = selected {
                    Divider()
                    WorkDetailsView(node: node, presentation: presentation, sessionIDs: sessionIDs,
                                    relevantImports: relevantImports, selection: $selection)
                        .frame(width: 280)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAdd) { AddGraphWorkView().environmentObject(store) }
        .sheet(isPresented: $showConnections) { WorkConnectionsView() }
        .onChange(of: store.workGraph.imports) { _, _ in fitRevision += 1 }
        .onChange(of: graph, initial: true) { _, _ in updateLayout() }
        .onChange(of: filter) { _, _ in updateLayout(); fitRevision += 1 }
        .onChange(of: collapsed) { _, _ in updateLayout(); fitRevision += 1 }
    }

    private func updateLayout() {
        let needsInitialFit = presentation.layout.frames.isEmpty
        presentation = WorkPresentation(graph: graph, filter: filter, collapsed: collapsed)
        if needsInitialFit { fitRevision += 1 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work").font(.title2.weight(.semibold))
                    Text("\(store.workLog == nil ? "Next session" : "This session") · \(sessionIDs.count) selected · \(graph.nodes.filter { !graph.descendants(of: sessionIDs).contains($0.id) }.count) in context")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showConnections = true } label: { Image(systemName: "key") }
                    .help("Connections").accessibilityLabel("Connections")
                Menu {
                    ForEach(relevantImports) { imported in
                        Button(store.workGraph.nodes.first { $0.id == imported.id }?.label ?? imported.url) {
                            store.importWork(imported.url, addToSession: false)
                        }
                    }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(store.workImporting || relevantImports.isEmpty || !store.workGraphWritable)
                Button("Add work", systemImage: "plus") { showAdd = true }
                    .disabled(store.workImporting || !store.workGraphWritable)
            }
            HStack {
                Picker("View", selection: $mode) {
                    ForEach(WorkViewMode.allCases, id: \.self) { Text($0.rawValue + " View").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(WorkFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 270)
            }
        }.padding(20)
    }

    private func toggleCollapsed(_ id: String) {
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if store.workImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Importing work…")
                    Button("Cancel") { store.workImportTask?.cancel() }
                }
            }
            if let message = store.workImportMessage {
                Text(message).textSelection(.enabled).lineLimit(3)
            }
            if !presentation.conflicts.isEmpty {
                Text("\(presentation.conflicts.count) conflicting dependencies need review.").foregroundStyle(.orange)
            }
            if mode == .graph {
                Text("Drag space to pan · Pinch to zoom · Muted cards are context")
                Text("Solid arrows: explicit order · Dashed arrows: inferred from branches")
            } else {
                Text("Select work to view dependencies · Check off work completed this session · Muted rows are context")
            }
        }.font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}
