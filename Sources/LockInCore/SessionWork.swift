import Foundation

extension Todo {
    public var workIdentity: String { workNodeID ?? "local:\(id.uuidString)" }
}

extension JournalState {
    public mutating func normalizeWorkEntries(using graph: WorkGraph) {
        func roots(_ tasks: [Todo]) -> [Todo] {
            let ids = graph.topLevelIDs(Set(tasks.map(\.workIdentity)))
            return tasks.filter { ids.contains($0.workIdentity) }.map { task in
                var task = task
                task.dependencyIDs = []
                return task
            }
        }
        draft = roots(draft)
        if let index = openSessionIndex { sessions[index].todos = roots(sessions[index].todos) }
    }

    public mutating func editCurrentWork(_ edit: (inout [Todo]) -> Void) {
        if let index = openSessionIndex { edit(&sessions[index].todos) }
        else { edit(&draft) }
    }
}

extension WorkGraph {
    /// Session completion updates local tasks; imported status belongs to its source.
    public func updatingLocalWork(from tasks: [Todo]) -> WorkGraph {
        var graph = self
        var indices = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        for task in tasks where task.hasTitle {
            let id = task.workIdentity
            if let index = indices[id] {
                guard graph.nodes[index].kind == .local else { continue }
                graph.nodes[index].title = task.title
                graph.nodes[index].url = task.link
                graph.nodes[index].resolved = task.completed
                graph.nodes[index].status = task.completed ? "Done" : "Open"
            } else {
                indices[id] = graph.nodes.count
                graph.nodes.append(WorkNode(id: id, kind: .local, title: task.title, url: task.link,
                                            status: task.completed ? "Done" : "Open", resolved: task.completed))
            }
        }
        return graph
    }
}
