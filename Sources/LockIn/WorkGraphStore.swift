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
        guard workGraphWritable, !workImporting else { throw LockInError("Work can't be added right now. Try again shortly.") }
        guard canPlanWork else { throw LockInError(Self.reviewFirstMessage) }
        let identity = input.identity
        let saved = WorkOperation.saved("Added “\(input.newTitle)” to \(workLog == nil ? "the next session's plan" : "this session").")
        // Work the session already covers, under its source's current name or the name it had when it was added.
        let covered = workGraph.descendants(of: sessionWorkIDs)
        let existing = sessionGraph.nodes.filter { covered.contains($0.id) }.map { (id: $0.id, title: $0.title, link: $0.url) }
            + graphSessionTasks.map { (id: $0.workIdentity, title: $0.title, link: $0.link) }
        if let match = existing.first(where: { input.matches(title: $0.title, link: $0.link) }) {
            try checkNotIncluded(match.id)
            throw LockInError(identity == nil ? "This task is already in the session." : "This link is already in the session.")
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
        guard workGraphWritable else { throw LockInError("Work can't be saved right now.") }
        do { try Storage.saveWorkGraph(graph, in: directory) }
        catch { throw LockInError("Couldn't save work: \(error.localizedDescription)") }
        workGraph = graph
    }

    @discardableResult
    func editWorkGraph(_ edit: (inout WorkGraph) -> Void) -> Bool {
        var graph = workGraph
        edit(&graph)
        return attemptWork { try saveWorkGraph(graph) }
    }

    /// Runs a Work view action, showing its error there if it throws.
    @discardableResult
    func attemptWork(_ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch { workImportMessage = error.localizedDescription; return false }
    }

    // The app and the CLI both change session work through these, so the same rules apply to each.
    // `id` is the work entry's identity: its work node's ID.

    /// Renames or relinks local work. Imported work takes its title and link from Linear or GitHub.
    func renameWork(_ id: String, title: String, link: String) throws {
        guard canPlanWork else { throw LockInError(Self.reviewFirstMessage) }
        guard let task = currentTask(id) else { throw noSuchWork }
        if let kind = workGraph.nodes.first(where: { $0.id == id })?.kind, kind != .local {
            throw LockInError("Imported work keeps its source's title and link. Change it in \(kind.destination).")
        }
        let updated = task.with(title: title, link: link)
        guard updated.hasTitle else { throw LockInError("A task needs a title.") }
        guard updated.validLink else { throw LockInError(Todo.linkRequirement) }
        try commitJournal { $0.editCurrentWork(id) { $0 = $0.with(title: title, link: link) } }
    }

    /// Checks work off, or back on. Only a running session's work can be done.
    func setWorkDone(_ id: String, done: Bool) throws {
        guard workLog != nil else { throw LockInError("Tasks can be checked off during a session.") }
        guard currentTask(id) != nil else { throw noSuchWork }
        try commitJournal { $0.editCurrentWork(id) { $0.completed = done } }
    }

    /// Removes work from the session or the plan. A session's record of it goes too.
    func removeWork(_ id: String) throws {
        guard canPlanWork else { throw LockInError(Self.reviewFirstMessage) }
        guard currentTask(id) != nil else { throw noSuchWork }
        try commitJournal { $0.removeCurrentWork { $0.workIdentity == id } }
    }

    func currentTask(_ id: String) -> Todo? { graphSessionTasks.first { $0.workIdentity == id } }

    private var noSuchWork: LockInError {
        LockInError(workLog == nil ? "No such task in the plan." : "No such task in this session.")
    }

    var sessionWorkIDs: Set<String> { Set(graphSessionTasks.map(\.workIdentity)) }

    var graphSessionTasks: [Todo] { journal.currentWork }

    var sessionGraph: WorkGraph {
        workGraph.updatingLocalWork(from: graphSessionTasks).focused(on: sessionWorkIDs)
    }

    func isSessionWorkDone(_ id: String) -> Bool { currentTask(id)?.completed ?? false }

    /// Throws if a selected entry already contains `id` in `graph`.
    func checkNotIncluded(_ id: String, in graph: WorkGraph? = nil) throws {
        guard let ancestor = (graph ?? workGraph).selectedAncestor(of: id, among: sessionWorkIDs) else { return }
        let parent = workGraph.nodes.first { $0.id == ancestor }
        let name = parent.map { $0.label == "Task" ? $0.title : $0.label } ?? ancestor
        throw LockInError("Already included through \(name).")
    }

    func normalizeSessionEntries() throws {
        var normalized = journal
        normalized.normalizeWorkEntries(using: workGraph)
        if normalized != journal { try commitJournal { $0 = normalized } }
    }

    func saveWorkSelection(_ nodes: [WorkNode]) throws {
        for node in nodes { try checkNotIncluded(node.id) }
        let selected = sessionWorkIDs
        let additions = nodes.filter { !selected.contains($0.id) }.uniqued(by: \.id).map(Todo.init(work:))
        try commitJournal { $0.addCurrentWork(additions) }
    }

    func syncLocalWork() {
        let graph = workGraph.updatingLocalWork(from: journal.plannedTasks + (workLog?.todos ?? []))
        if graph != workGraph { editWorkGraph { $0 = graph } }
    }
}
