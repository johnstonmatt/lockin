import Foundation
import LockInCore

extension Store {
    @discardableResult
    func addWork(_ text: String, using importer: WorkImporter = WorkConnections.importer) throws -> WorkOperation {
        try addWork(WorkInput(text), using: importer)
    }

    @discardableResult
    func addWork(_ input: WorkInput, using importer: WorkImporter = WorkConnections.importer) throws -> WorkOperation {
        try input.validate()
        guard workGraphWritable, !workImporting else { throw WorkImportError("Work can't be added right now. Try again shortly.") }
        guard workLog != nil || journal.pendingReviewID == nil else {
            throw WorkImportError("Review your last session in Lock In before planning the next one.")
        }
        let identity = input.identity
        let saved = WorkOperation.saved("Added “\(input.newTitle)” to \(workLog == nil ? "the next session's plan" : "this session").")
        // Links match by identity; plain task names match case-insensitively.
        func matches(title: String, link: String) -> Bool {
            if let identity { return WorkInput.linkIdentity(link) == identity }
            return title.trimmed.caseInsensitiveCompare(input.newTitle) == .orderedSame
        }
        let covered = workGraph.descendants(of: sessionWorkIDs)
        let selected = sessionGraph.nodes.filter { covered.contains($0.id) }
        if let existing = selected.first(where: { matches(title: $0.title, link: $0.url) }),
           let ancestor = workGraph.selectedAncestor(of: existing.id, among: sessionWorkIDs) {
            throw WorkImportError(parentEntryMessage(ancestor))
        }
        if selected.contains(where: { matches(title: $0.title, link: $0.url) })
            || graphSessionTasks.contains(where: { matches(title: $0.title, link: $0.link) }) {
            throw WorkImportError(identity == nil ? "This task is already in the session." : "This link is already in the session.")
        }
        if let identity {
            if let existing = workGraph.visibleNodes.first(where: { WorkInput.linkIdentity($0.url) == identity }) {
                if let ancestor = workGraph.selectedAncestor(of: existing.id, among: sessionWorkIDs) {
                    throw WorkImportError(parentEntryMessage(ancestor))
                }
                try saveWorkSelection([existing])
                if let url = input.importURL {
                    return try importWork(url, addToSession: false, using: importer)
                }
                return saved
            }
            if let url = input.importURL { return try importWork(url, using: importer) }
        }
        let node = WorkNode(id: "local:\(UUID().uuidString)", kind: .local, title: input.newTitle, url: identity == nil ? "" : input.source)
        var graph = workGraph
        graph.nodes.append(node)
        try saveWorkGraph(graph)
        try saveWorkSelection([node])
        return saved
    }

    func saveWorkGraph(_ graph: WorkGraph) throws {
        guard workGraphWritable else { throw WorkImportError("Work can't be saved right now.") }
        do { try WorkGraphStorage.save(graph, in: workDirectory) }
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
        commitJournal { journal in
            journal.editCurrentWork { tasks in
                for index in tasks.indices where tasks[index].workIdentity == id {
                    tasks[index] = tasks[index].with(title: title, link: link)
                }
            }
        }
    }

    var sessionWorkIDs: Set<String> {
        Set((workLog?.todos ?? journal.draft).map(\.workIdentity))
    }

    var graphSessionTasks: [Todo] { workLog?.todos ?? journal.plannedTasks }

    var sessionGraph: WorkGraph {
        workGraph.updatingLocalWork(from: graphSessionTasks).focused(on: sessionWorkIDs)
    }

    func isSessionWorkDone(_ id: String) -> Bool {
        graphSessionTasks.first { $0.workIdentity == id }?.completed ?? false
    }

    func parentEntryMessage(_ id: String) -> String {
        let parent = workGraph.nodes.first { $0.id == id }
        return "Already included through \(parent?.label == "Task" ? parent?.title ?? id : parent?.label ?? id)."
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
        for node in nodes {
            if let ancestor = workGraph.selectedAncestor(of: node.id, among: sessionWorkIDs) {
                throw WorkImportError(parentEntryMessage(ancestor))
            }
        }
        var selected = sessionWorkIDs
        let additions = nodes.compactMap { node -> Todo? in
            guard selected.insert(node.id).inserted else { return nil }
            var todo = Todo(title: node.title)
            todo.link = node.url; todo.workNodeID = node.id
            return todo
        }
        guard commitJournal({ journal in
            if let index = journal.openSessionIndex { journal.sessions[index].todos += additions }
            else { journal.setPlan(journal.plannedTasks + additions) }
        }) else { throw WorkImportError(message ?? "Couldn't save this work to the session.") }
    }

    func removeWorkFromSession(_ id: String) {
        commitJournal { journal in
            if let index = journal.openSessionIndex {
                journal.sessions[index].todos.removeAll { $0.workIdentity == id }
            } else { journal.setPlan(journal.plannedTasks.filter { $0.workIdentity != id }) }
        }
    }

    func setSessionWorkDone(_ id: String, done: Bool) {
        guard sessionWorkIDs.contains(id) else { return }
        commitJournal { journal in
            journal.editCurrentWork { tasks in
                for index in tasks.indices where tasks[index].workIdentity == id { tasks[index].completed = done }
            }
        }
    }

    func syncLocalWork() {
        let graph = workGraph.updatingLocalWork(from: journal.plannedTasks + (workLog?.todos ?? []))
        if graph != workGraph { editWorkGraph { $0 = graph } }
    }
}
