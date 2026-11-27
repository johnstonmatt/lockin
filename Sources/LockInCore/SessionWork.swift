import Foundation

extension Todo {
    public var workIdentity: String { workNodeID ?? WorkNode.localID(id) }

    /// A session entry for a work node.
    public init(work node: WorkNode) {
        self.init(title: node.title)
        link = node.url
        workNodeID = node.id
    }
}

extension WorkNode {
    public static func localID(_ id: UUID = UUID()) -> String { "local:\(id.uuidString)" }

    public init(localTask task: Todo) {
        self.init(id: task.workIdentity, kind: .local, title: task.title)
        update(from: task)
    }

    mutating func update(from task: Todo) {
        title = task.title
        url = task.link
        resolved = task.completed
        status = task.completed ? "Done" : "Open"
    }
}

extension JournalState {
    /// The running session's tasks, or the plan's.
    public var currentWork: [Todo] { openSession?.todos ?? plannedTasks }

    public mutating func normalizeWorkEntries(using graph: WorkGraph) {
        func roots(_ tasks: [Todo]) -> [Todo] {
            let ids = graph.topLevelIDs(Set(tasks.map(\.workIdentity)))
            return tasks.filter { ids.contains($0.workIdentity) }
        }
        draft = roots(draft)
        if let index = openSessionIndex { sessions[index].todos = roots(sessions[index].todos) }
    }

    public mutating func editCurrentWork(_ edit: (inout [Todo]) -> Void) {
        if let index = openSessionIndex { edit(&sessions[index].todos) }
        else { edit(&draft) }
    }

    /// Applies `edit` to every current task for the work entry `id`.
    public mutating func editCurrentWork(_ id: String, _ edit: (inout Todo) -> Void) {
        editCurrentWork { tasks in
            for index in tasks.indices where tasks[index].workIdentity == id { edit(&tasks[index]) }
        }
    }

    public mutating func addCurrentWork(_ tasks: [Todo]) {
        if let index = openSessionIndex { sessions[index].todos += tasks }
        else { setPlan(plannedTasks + tasks) }
    }

    public mutating func removeCurrentWork(where shouldRemove: (Todo) -> Bool) {
        if let index = openSessionIndex { sessions[index].todos.removeAll(where: shouldRemove) }
        else { setPlan(plannedTasks.filter { !shouldRemove($0) }) }
    }
}

extension WorkGraph {
    /// Session completion updates local tasks; imported status belongs to its source.
    public func updatingLocalWork(from tasks: [Todo]) -> WorkGraph {
        var graph = self
        var indices = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        for task in tasks where task.hasTitle {
            if let index = indices[task.workIdentity] {
                guard graph.nodes[index].kind == .local else { continue }
                graph.nodes[index].update(from: task)
            } else {
                indices[task.workIdentity] = graph.nodes.count
                graph.nodes.append(WorkNode(localTask: task))
            }
        }
        return graph
    }
}
