import XCTest
@testable import LockInCore

final class TaskGraphTests: XCTestCase {
    func testBranchesJoinAndCompletion() {
        var issue = Todo(title: "Issue")
        var first = Todo(title: "First PR"); first.dependencyIDs = [issue.id]
        var second = Todo(title: "Second PR"); second.dependencyIDs = [issue.id]
        var ship = Todo(title: "Ship"); ship.dependencyIDs = [first.id, second.id]
        var graph = TaskGraph(tasks: [ship, first, issue, second])
        XCTAssertEqual(graph.layers.map { $0.map(\.id) }, [[issue.id], [first.id, second.id], [ship.id]])
        XCTAssertTrue(graph.isBlocked(first))
        XCTAssertFalse(graph.canDepend(issue.id, on: ship.id))
        XCTAssertFalse(graph.canDepend(issue.id, on: issue.id))
        XCTAssertFalse(graph.canDepend(issue.id, on: UUID()))
        XCTAssertTrue(graph.canDepend(second.id, on: first.id))
        issue.completed = true
        graph = TaskGraph(tasks: [issue, first, second, ship])
        XCTAssertFalse(graph.isBlocked(first))
        XCTAssertTrue(graph.isBlocked(ship))
    }

    func testSequencingAddsRemovesAndReversesConnections() throws {
        let first = Todo(title: "First")
        let second = Todo(title: "Second")
        let unrelated = Todo(title: "Unrelated")
        let connected = try XCTUnwrap(TaskGraph(tasks: [first, second, unrelated])
            .sequencing(upstream: first.id, downstream: second.id))
        XCTAssertEqual(connected[1].dependencyIDs, [first.id])
        let repeated = try XCTUnwrap(TaskGraph(tasks: connected)
            .sequencing(upstream: first.id, downstream: second.id))
        XCTAssertEqual(repeated, [first, second, unrelated])
        let reconnected = try XCTUnwrap(TaskGraph(tasks: repeated)
            .sequencing(upstream: first.id, downstream: second.id))
        XCTAssertEqual(reconnected, connected)
        let reversed = try XCTUnwrap(TaskGraph(tasks: connected)
            .sequencing(upstream: second.id, downstream: first.id))
        XCTAssertEqual(reversed[0].dependencyIDs, [second.id])
        XCTAssertTrue(reversed[1].dependencyIDs.isEmpty)
        XCTAssertEqual(reversed[2], unrelated)
    }

    func testRemovingConnectionPreservesOtherDependencies() throws {
        let first = Todo(title: "First")
        let second = Todo(title: "Second")
        var third = Todo(title: "Third"); third.dependencyIDs = [first.id, second.id]
        let updated = try XCTUnwrap(TaskGraph(tasks: [first, second, third])
            .sequencing(upstream: first.id, downstream: third.id))
        XCTAssertEqual(updated[2].dependencyIDs, [second.id])
        XCTAssertEqual(updated[0], first)
        XCTAssertEqual(updated[1], second)
        XCTAssertTrue(TaskGraph(tasks: updated).isBlocked(updated[2]))
    }

    func testSequencingRejectsIndirectCyclesAndInvalidTasks() {
        let first = Todo(title: "First")
        var second = Todo(title: "Second"); second.dependencyIDs = [first.id]
        var third = Todo(title: "Third"); third.dependencyIDs = [first.id, second.id]
        let graph = TaskGraph(tasks: [first, second, third])
        XCTAssertNil(graph.sequencing(upstream: third.id, downstream: first.id))
        XCTAssertNil(graph.sequencing(upstream: first.id, downstream: first.id))
        XCTAssertNil(graph.sequencing(upstream: UUID(), downstream: first.id))
        XCTAssertNil(graph.sequencing(upstream: first.id, downstream: UUID()))
        XCTAssertEqual(graph.tasks[2].dependencyIDs, [first.id, second.id])
    }

    func testDeletionAndMalformedCycle() {
        var first = Todo(title: "First")
        var second = Todo(title: "Second")
        first.dependencyIDs = [second.id]; second.dependencyIDs = [first.id]
        XCTAssertEqual(TaskGraph(tasks: [first, second]).layers.flatMap { $0 }.count, 2)
        XCTAssertEqual(TaskGraph.removingMissingDependencies([first])[0].dependencyIDs, [])
    }

    func testRolloverRemapsOnlySelectedTasks() {
        var first = Todo(title: "Issue"); first.rollForward = true
        var second = Todo(title: "PR"); second.rollForward = true; second.dependencyIDs = [first.id]
        let omitted = Todo(title: "Omitted")
        second.dependencyIDs.append(omitted.id)
        let log = WorkLog(todos: [first, second, omitted], targetSeconds: 3600, now: Date())
        let rolled = log.rolledTodos
        XCTAssertEqual(rolled.count, 2)
        XCTAssertNotEqual(rolled[0].id, first.id)
        XCTAssertEqual(rolled[1].dependencyIDs, [rolled[0].id])
        XCTAssertEqual(rolled[1].sourceTodoID, second.id)
    }

    func testDependencySerializationAndOlderRecords() throws {
        var task = Todo(title: "PR"); task.dependencyIDs = [UUID()]
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(TaskRecord(task))
        XCTAssertEqual(try decoder.decode(TaskRecord.self, from: data).todo, task)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "dependency_ids")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try decoder.decode(TaskRecord.self, from: older).todo.dependencyIDs, [])
    }
}
