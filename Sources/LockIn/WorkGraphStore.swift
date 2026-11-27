import Foundation
import LockInCore

extension Store {
    @discardableResult
    func addWork(_ text: String, using importer: WorkImporter? = nil) throws -> WorkOperation {
        try addWork(WorkInput(text), using: importer)
    }

    @discardableResult
    func addWork(_ input: WorkInput, using importer: WorkImporter? = nil) throws -> WorkOperation {
        try input.validate()
        guard workGraphWritable, !workImporting else { throw WorkImportError("Work can't be added right now. Try again shortly.") }
        guard canPlanWork else { throw WorkImportError(Self.reviewFirstMessage) }
        let identity = input.identity
        let saved = WorkOperation.saved("Added “\(input.newTitle)” to \(workLog == nil ? "the next session's plan" : "this session").")
        // Links match by identity; plain task names match case-insensitively.
        func matches(title: String, link: String) -> Bool {
            if let identity { return WorkInput.linkIdentity(link) == identity }
            return title.trimmed.caseInsensitiveCompare(input.newTitle) == .orderedSame
        }
        let covered = workGraph.descendants(of: sessionWorkIDs)
        if let existing = sessionGraph.nodes.first(where: { covered.contains($0.id) && matches(title: $0.title, link: $0.url) }) {
            try checkNotIncluded(existing.id)
            throw WorkImportError(identity == nil ? "This task is already in the session." : "This link is already in the session.")
        }
        if graphSessionTasks.contains(where: { matches(title: $0.title, link: $0.link) }) {
            throw WorkImportError(identity == nil ? "This task is already in the session." : "This link is already in the session.")
        }
        if let identity {
            if let existing = workGraph.nodes.first(where: { WorkInput.linkIdentity($0.url) == identity }) {
                try saveWorkSelection([existing])
                if let url = input.importURL {
                    return try importWork(url, addToSession: false, using: importer)
                }
                return saved
            }
            if let url = input.importURL { return try importWork(url, using: importer) }
        }
        let node = WorkNode(id: WorkNode.localID(), kind: .local, title: input.newTitle, url: identity == nil ? "" : input.source)
        var graph = workGraph
        graph.nodes.append(node)
        try saveWorkGraph(graph)
        try saveWorkSelection([node])
        return saved
    }

    func saveWorkGraph(_ graph: WorkGraph) throws {
        guard workGraphWritable else { throw WorkImportError("Work can't be saved right now.") }
        do { try WorkGraphStorage.save(graph, in: directory) }
        catch { throw WorkImportError("Couldn't save work: \(error.localizedDescription)") }
        workGraph = graph
    }

    @discardableResult
    func editWorkGraph(_ edit: (inout WorkGraph) -> Void) -> Bool {
        var graph = workGraph
        edit(&graph)
        do { try saveWorkGraph(graph); return true }
        catch { workImportMessage = error.localizedDescription; return false }
    }

    func renameSessionWork(_ id: String, title: String, link: String) {
        guard sessionWorkIDs.contains(id), sessionGraph.nodes.first(where: { $0.id == id })?.kind == .local,
              Todo().with(title: title, link: link).isValid else { return }
        commitJournal { $0.editCurrentWork(id) { $0 = $0.with(title: title, link: link) } }
    }

    var sessionWorkIDs: Set<String> { Set(graphSessionTasks.map(\.workIdentity)) }

    var graphSessionTasks: [Todo] { journal.currentWork }

    var sessionGraph: WorkGraph {
        workGraph.updatingLocalWork(from: graphSessionTasks).focused(on: sessionWorkIDs)
    }

    func isSessionWorkDone(_ id: String) -> Bool {
        graphSessionTasks.first { $0.workIdentity == id }?.completed ?? false
    }

    /// Throws if a selected entry already contains `id` in `graph`.
    func checkNotIncluded(_ id: String, in graph: WorkGraph? = nil) throws {
        guard let ancestor = (graph ?? workGraph).selectedAncestor(of: id, among: sessionWorkIDs) else { return }
        let parent = workGraph.nodes.first { $0.id == ancestor }
        let name = parent.map { $0.label == "Task" ? $0.title : $0.label } ?? ancestor
        throw WorkImportError("Already included through \(name).")
    }

    @discardableResult
    func normalizeSessionEntries() -> Bool {
        var normalized = journal
        normalized.normalizeWorkEntries(using: workGraph)
        return normalized == journal || commitJournal { $0 = normalized }
    }

    @discardableResult
    func selectWorkForSession(_ node: WorkNode) -> Bool { selectWorkForSession([node]) }

    @discardableResult
    func selectWorkForSession(_ nodes: [WorkNode]) -> Bool {
        do { try saveWorkSelection(nodes); return true }
        catch { workImportMessage = error.localizedDescription; return false }
    }

    func saveWorkSelection(_ nodes: [WorkNode]) throws {
        for node in nodes { try checkNotIncluded(node.id) }
        let selected = sessionWorkIDs
        let additions = nodes.filter { !selected.contains($0.id) }.uniqued(by: \.id).map(Todo.init(work:))
        guard commitJournal({ $0.addCurrentWork(additions) }) else {
            throw WorkImportError(message ?? "Couldn't save this work to the session.")
        }
    }

    func removeWorkFromSession(_ id: String) {
        commitJournal { $0.removeCurrentWork { $0.workIdentity == id } }
    }

    func setSessionWorkDone(_ id: String, done: Bool) {
        guard sessionWorkIDs.contains(id) else { return }
        commitJournal { $0.editCurrentWork(id) { $0.completed = done } }
    }

    func syncLocalWork() {
        let graph = workGraph.updatingLocalWork(from: journal.plannedTasks + (workLog?.todos ?? []))
        if graph != workGraph { editWorkGraph { $0 = graph } }
    }
}
