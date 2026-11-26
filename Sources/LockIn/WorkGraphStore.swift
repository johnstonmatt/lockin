import Foundation
import LockInCore

extension Store {
    func addWork(_ input: String) throws {
        let text = input.trimmed
        guard !text.isEmpty else { throw WorkImportError("Enter a URL or task name.") }
        guard workGraphWritable, !workImporting else { throw WorkImportError("Work can't be added right now. Try again shortly.") }
        let identity = WorkInput.linkIdentity(text)
        let covered = workGraph.descendants(of: sessionWorkIDs)
        let selected = sessionGraph.nodes.filter { covered.contains($0.id) }
        if let existing = selected.first(where: {
            if let identity { return WorkInput.linkIdentity($0.url) == identity }
            return $0.title.trimmed.caseInsensitiveCompare(text) == .orderedSame
        }), let ancestor = workGraph.selectedAncestor(of: existing.id, among: sessionWorkIDs) {
            throw WorkImportError(parentEntryMessage(ancestor))
        }
        if identity == nil && (selected.contains(where: { $0.title.trimmed.caseInsensitiveCompare(text) == .orderedSame }) ||
            graphSessionTasks.contains(where: { $0.title.trimmed.caseInsensitiveCompare(text) == .orderedSame })) {
            throw WorkImportError("This task is already in the session.")
        }
        if let identity {
            if selected.contains(where: { WorkInput.linkIdentity($0.url) == identity }) ||
                graphSessionTasks.contains(where: { WorkInput.linkIdentity($0.link) == identity }) {
                throw WorkImportError("This link is already in the session.")
            }
            if let existing = workGraph.visibleNodes.first(where: { WorkInput.linkIdentity($0.url) == identity }) {
                if let ancestor = workGraph.selectedAncestor(of: existing.id, among: sessionWorkIDs) {
                    throw WorkImportError(parentEntryMessage(ancestor))
                }
                guard selectWorkForSession(existing) else { throw WorkImportError(workImportMessage ?? "Couldn't save this work to the session.") }
                return
            }
            if LinearGraphClient.issueIdentifier(from: text) != nil || PullRequestReference(url: text) != nil {
                importWork(text)
                return
            }
        } else if text.contains("://") || text.lowercased().hasPrefix("www.") {
            throw WorkImportError(Todo.linkRequirement)
        }
        let node = WorkNode(id: "local:\(UUID().uuidString)", kind: .local, title: text, url: identity == nil ? "" : text)
        guard editWorkGraph({ $0.nodes.append(node) }), selectWorkForSession(node) else {
            throw WorkImportError("Couldn't save this work to the session.")
        }
    }

    @discardableResult
    func editWorkGraph(_ edit: (inout WorkGraph) -> Void) -> Bool {
        guard workGraphWritable else { return false }
        var graph = workGraph
        edit(&graph)
        do {
            try WorkGraphStorage.save(graph, in: workDirectory)
            workGraph = graph
            return true
        } catch {
            workImportMessage = "Couldn't save work: \(error.localizedDescription)"
            return false
        }
    }

    func importWork(_ input: String, addToSession: Bool = true, using importer: WorkImporter = WorkConnections.importer) {
        guard !workImporting, workGraphWritable else { return }
        let targetSession = workLog?.id
        workImporting = true
        workImportMessage = "Loading work and dependencies…"
        workImportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.workImporting = false; self.workImportTask = nil }
            do {
                let result = try await importer.fetch(input, preserving: Set(self.workGraph.imports.map(\.id)))
                self.applyWorkImport(result, addToSession: addToSession, targetSession: targetSession)
            } catch is CancellationError {
                self.workImportMessage = "Import canceled. Saved work is unchanged."
            } catch {
                self.workImportMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func applyWorkImport(_ result: WorkImportResult, addToSession: Bool, targetSession: UUID?) -> Bool {
        var candidate = workGraph
        candidate.merge(result)
        if addToSession && workLog?.id == targetSession,
           let ancestor = candidate.selectedAncestor(of: result.snapshot.id, among: sessionWorkIDs) {
            workImportMessage = parentEntryMessage(ancestor)
            return false
        }
        guard editWorkGraph({ $0.merge(result) }) else { return false }
        if addToSession && workLog?.id == targetSession {
            let selected = result.nodes.filter { $0.id == result.snapshot.id }
            guard selectWorkForSession(selected) else {
                workImportMessage = "Graph saved, but session tasks couldn't be saved. Add the saved work again to retry."
                return false
            }
        }
        normalizeSessionEntries()
        workImportMessage = result.snapshot.warnings.isEmpty
            ? "Imported \(result.nodes.count) work items."
            : result.snapshot.warnings.joined(separator: "\n")
        if addToSession && workLog?.id != targetSession {
            workImportMessage = "Graph saved. The session changed during import; add its URL again to include it."
        }
        return true
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

    private func parentEntryMessage(_ id: String) -> String {
        let parent = workGraph.nodes.first { $0.id == id }
        return "Already included through \(parent?.label == "Task" ? parent?.title ?? id : parent?.label ?? id)."
    }

    func normalizeSessionEntries() {
        var normalized = journal
        normalized.normalizeWorkEntries(using: workGraph)
        if normalized != journal { commitJournal { $0 = normalized } }
    }

    @discardableResult
    func selectWorkForSession(_ node: WorkNode) -> Bool { selectWorkForSession([node]) }

    @discardableResult
    func selectWorkForSession(_ nodes: [WorkNode]) -> Bool {
        for node in nodes {
            if let ancestor = workGraph.selectedAncestor(of: node.id, among: sessionWorkIDs) {
                workImportMessage = parentEntryMessage(ancestor)
                return false
            }
        }
        var selected = sessionWorkIDs
        let additions = nodes.compactMap { node -> Todo? in
            guard selected.insert(node.id).inserted else { return nil }
            var todo = Todo(title: node.title)
            todo.link = node.url; todo.workNodeID = node.id
            return todo
        }
        return commitJournal { journal in
            if let index = journal.openSessionIndex { journal.sessions[index].todos += additions }
            else { journal.setPlan(journal.plannedTasks + additions) }
        }
    }

    func removeWorkFromSession(_ id: String) {
        commitJournal { journal in
            func keep(_ task: Todo) -> Bool { task.workIdentity != id }
            if let index = journal.openSessionIndex {
                journal.sessions[index].todos.removeAll { !keep($0) }
            } else { journal.setPlan(journal.plannedTasks.filter(keep)) }
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
