import XCTest
import SwiftUI
import AppKit
import LockInCore
@testable import LockIn

final class WorkGraphRenderTests: XCTestCase {
    @MainActor func testRenderSessionGraph() throws {
        guard let output = ProcessInfo.processInfo.environment["LOCKIN_GRAPH_PREVIEW"] else {
            throw XCTSkip("Set LOCKIN_GRAPH_PREVIEW to render a manual UI review image.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory, runTimer: false, enforceBlocking: false, channel: nil)
        var nodes = [
            WorkNode(id: "parent", kind: .linear, title: "Make focused work resumable", label: "ENG-100", status: "In progress"),
            WorkNode(id: "issue", kind: .linear, title: "Support session restoration", label: "ENG-124", status: "In review"),
            WorkNode(id: "base", kind: .pullRequest, title: "Persist session state", label: "app#81", status: "Merged", resolved: true, context: true),
            WorkNode(id: "api", kind: .pullRequest, title: "Restore the active session on launch", label: "app#84", status: "Open"),
            WorkNode(id: "ui", kind: .pullRequest, title: "Show restored work in the graph", label: "app#85", status: "Draft")
        ]
        nodes[3].readiness = PullRequestReadiness(checks: "SUCCESS", reviewDecision: "APPROVED", mergeState: "CLEAN", isDraft: false, headOID: "abc")
        nodes[4].readiness = PullRequestReadiness(checks: "SUCCESS", reviewDecision: "REVIEW_REQUIRED", mergeState: "BLOCKED", isDraft: false, headOID: "def")
        let snapshot = WorkImport(id: "parent", url: "", nodeIDs: nodes.map(\.id), edges: [
            WorkEdge(from: "parent", to: "issue", kind: .contains, source: .linear),
            WorkEdge(from: "issue", to: "api", kind: .implements, source: .linear),
            WorkEdge(from: "issue", to: "ui", kind: .implements, source: .linear),
            WorkEdge(from: "base", to: "api", kind: .depends, source: .stack),
            WorkEdge(from: "api", to: "ui", kind: .depends, source: .stack)
        ])
        store.applyWorkImport(WorkImportResult(nodes: nodes, snapshot: snapshot), addToSession: true, targetSession: nil)
        if ProcessInfo.processInfo.environment["LOCKIN_GRAPH_COMPLEX"] != nil {
            store.workGraph = WorkGraph()
            store.commitJournal { $0.setPlan([]) }
            store.applyWorkImport(WorkGraphLayoutTests.fixture(), addToSession: true, targetSession: nil)
        }
        if let source = ProcessInfo.processInfo.environment["LOCKIN_GRAPH_DATA"] {
            let sourceDirectory = URL(fileURLWithPath: source)
            store.workGraph = try XCTUnwrap(WorkGraphStorage.load(from: sourceDirectory))
            store.journal = try Storage.load(from: sourceDirectory).journal
            store.normalizeSessionEntries()
            store.workImportMessage = nil
            let presentation = WorkPresentation(graph: store.sessionGraph, filter: .all, collapsed: [])
            let layout = presentation.layout
            let planned = presentation.routes
            XCTAssertEqual(WorkEdgeRoute.obstructionCost(routes: planned, edges: presentation.dependencies, layout: layout), 0,
                           "Connectors must not cross unrelated cards or region headers")
            if let geometry = ProcessInfo.processInfo.environment["LOCKIN_GRAPH_GEOMETRY"] {
                let object: [String: Any] = [
                    "frames": layout.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
                    "groups": Dictionary(uniqueKeysWithValues: layout.groups.map { ($0.id, [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height]) }),
                    "routes": planned.mapValues { $0.points.map { [$0.x, $0.y] } }
                ]
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: URL(fileURLWithPath: geometry))
            }
            let routeIDs = planned.keys.sorted()
            for (index, firstID) in routeIDs.enumerated() {
                for secondID in routeIDs.dropFirst(index + 1) {
                    for (a, b) in zip(planned[firstID]!.points, planned[firstID]!.points.dropFirst()) {
                        for (c, d) in zip(planned[secondID]!.points, planned[secondID]!.points.dropFirst()) {
                            XCTAssertFalse(WorkEdgeRoute.crosses(a, b, c, d), "Crossing: \(planned[firstID]!.points) / \(planned[secondID]!.points)")
                        }
                    }
                }
            }
            let rects = Array(layout.frames.values)
            for i in rects.indices {
                for j in rects.indices where j > i { XCTAssertFalse(rects[i].intersects(rects[j])) }
            }
            for group in layout.groups {
                for id in group.memberIDs {
                    if let rect = layout.frames[id] { XCTAssertTrue(group.rect.contains(rect)) }
                }
            }
            for edge in store.sessionGraph.sequencing.edges {
                if let source = layout.frames[edge.from], let target = layout.frames[edge.to] {
                    XCTAssertLessThan(source.maxY, target.minY)
                }
            }
        }
        let suite = "lockin-preview-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        for mode in WorkViewMode.allCases {
            preferences.set(mode.rawValue, forKey: "workViewMode")
            let view = NSHostingView(rootView: WorkView().defaultAppStorage(preferences).environmentObject(store).tint(accent).frame(width: 1000, height: 720))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: output)
            let destination = mode == .graph ? url : url.deletingPathExtension().appendingPathExtension("list.png")
            try data.write(to: destination)
            XCTAssertGreaterThan(data.count, 1000)
        }
    }
}
