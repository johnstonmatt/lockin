import Foundation

public struct TaskGraph {
    public let tasks: [Todo]
    public init(tasks: [Todo]) { self.tasks = tasks }

    public func canDepend(_ taskID: UUID, on dependencyID: UUID) -> Bool {
        let ids = Set(tasks.map(\.id))
        guard taskID != dependencyID, ids.contains(taskID), ids.contains(dependencyID) else { return false }
        var pending = [dependencyID]
        var visited = Set<UUID>()
        while let id = pending.popLast() {
            if id == taskID { return false }
            guard visited.insert(id).inserted else { continue }
            pending += tasks.first { $0.id == id }?.dependencyIDs ?? []
        }
        return true
    }

    /// Repeating a connection removes it; reversing it must keep other dependencies acyclic.
    public func sequencing(upstream: UUID, downstream: UUID) -> [Todo]? {
        guard upstream != downstream,
              let upstreamIndex = tasks.firstIndex(where: { $0.id == upstream }),
              let downstreamIndex = tasks.firstIndex(where: { $0.id == downstream }) else { return nil }
        var updated = tasks
        if updated[downstreamIndex].dependencyIDs.contains(upstream) {
            updated[downstreamIndex].dependencyIDs.removeAll { $0 == upstream }
            return updated
        }
        updated[upstreamIndex].dependencyIDs.removeAll { $0 == downstream }
        guard TaskGraph(tasks: updated).canDepend(downstream, on: upstream) else { return nil }
        updated[downstreamIndex].dependencyIDs.append(upstream)
        return updated
    }

    public func isBlocked(_ task: Todo) -> Bool {
        !task.completed && task.dependencyIDs.contains { id in
            tasks.first { $0.id == id }?.completed != true
        }
    }

    /// Kahn layers keep prerequisites first; malformed cycles stay visible in a final layer.
    public var layers: [[Todo]] {
        var remaining = tasks
        var placed = Set<UUID>()
        let ids = Set(tasks.map(\.id))
        var result: [[Todo]] = []
        while !remaining.isEmpty {
            let layer = remaining.filter { Set($0.dependencyIDs).intersection(ids).isSubset(of: placed) }
            if layer.isEmpty { result.append(remaining); break }
            result.append(layer)
            placed.formUnion(layer.map(\.id))
            remaining.removeAll { placed.contains($0.id) }
        }
        return result
    }

    public static func removingMissingDependencies(_ tasks: [Todo]) -> [Todo] {
        let ids = Set(tasks.map(\.id))
        return tasks.map { task in
            var copy = task
            copy.dependencyIDs.removeAll { !ids.contains($0) }
            return copy
        }
    }
}
