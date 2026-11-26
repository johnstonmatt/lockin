import XCTest
@testable import LockInCore

final class SessionWorkTests: XCTestCase {
    func testIdentityUsesSourceIDOrStableLocalID() {
        var task = Todo(title: "Task")
        XCTAssertEqual(task.workIdentity, "local:\(task.id.uuidString)")
        task.workNodeID = "github:repo#1"
        XCTAssertEqual(task.workIdentity, "github:repo#1")
    }

    func testDraftEditingPreservesBlankPlannerRows() {
        var journal = JournalState()
        let task = Todo(title: "Task")
        let blank = Todo()
        journal.draft = [task, blank]
        journal.editCurrentWork { $0[0].completed = true }
        XCTAssertTrue(journal.draft[0].completed)
        XCTAssertEqual(journal.draft[1], blank)
    }

    func testLocalOverlayPreservesSourceNodesAndOriginalGraph() {
        var local = Todo(title: "Local")
        local.completed = true
        var remoteTask = Todo(title: "Session title")
        remoteTask.workNodeID = "github:repo#1"
        remoteTask.completed = true
        let remote = WorkNode(id: remoteTask.workIdentity, kind: .pullRequest, title: "Source title", status: "Passing")
        var graph = WorkGraph()
        graph.nodes = [remote]
        let overlay = graph.updatingLocalWork(from: [local, remoteTask, Todo(), local])
        XCTAssertEqual(graph.nodes, [remote])
        XCTAssertEqual(overlay.nodes.count, 2)
        XCTAssertEqual(overlay.nodes.first, remote)
        XCTAssertEqual(overlay.nodes.last?.status, "Done")
        XCTAssertEqual(overlay.nodes.last?.resolved, true)
        local.title = "Renamed"
        local.completed = false
        let updated = overlay.updatingLocalWork(from: [local])
        XCTAssertEqual(updated.nodes.last?.title, "Renamed")
        XCTAssertEqual(updated.nodes.last?.status, "Open")
        XCTAssertEqual(updated.nodes.last?.resolved, false)
    }
}
