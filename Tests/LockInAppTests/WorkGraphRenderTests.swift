import XCTest
import SwiftUI
import AppKit
import LockInCore
@testable import LockIn

final class WorkGraphRenderTests: StoreTestCase {
    static func fixture() -> WorkImportResult {
        var nodes = [
            WorkNode(id: "parent", kind: .linear, title: "Make focused work resumable", label: "ENG-100", status: "In progress"),
            WorkNode(id: "issue", kind: .linear, title: "Support session restoration", label: "ENG-124", status: "In review"),
            WorkNode(id: "base", kind: .pullRequest, title: "Persist session state", label: "app#81", status: "Merged", resolved: true, context: true),
            WorkNode(id: "api", kind: .pullRequest, title: "Restore the active session on launch", label: "app#84", status: "Open"),
            WorkNode(id: "ui", kind: .pullRequest, title: "Show restored work in the graph", label: "app#85", status: "Draft")
        ]
        nodes[3].readiness = PullRequestReadiness(checks: "SUCCESS", reviewDecision: "APPROVED", mergeState: "CLEAN", isDraft: false, headOID: "abc")
        nodes[4].readiness = PullRequestReadiness(checks: "SUCCESS", reviewDecision: "REVIEW_REQUIRED", mergeState: "BLOCKED", isDraft: false, headOID: "def")
        let snapshot = WorkImport.fixture(id: "parent", nodeIDs: nodes.map(\.id), edges: [
            WorkEdge(from: "parent", to: "issue", kind: .contains, source: .linear),
            WorkEdge(from: "issue", to: "api", kind: .implements, source: .linear),
            WorkEdge(from: "issue", to: "ui", kind: .implements, source: .linear),
            WorkEdge(from: "base", to: "api", kind: .depends, source: .stack),
            WorkEdge(from: "api", to: "ui", kind: .depends, source: .stack)
        ])
        return WorkImportResult(nodes: nodes, snapshot: snapshot)
    }

    @MainActor func testRenderSessionGraph() throws {
        guard let output = ProcessInfo.processInfo.environment["LOCKIN_GRAPH_PREVIEW"] else {
            throw XCTSkip("Set LOCKIN_GRAPH_PREVIEW to render a manual UI review image.")
        }
        let store = makeStore()
        try store.applyWorkImport(Self.fixture(), addToSession: true, targetSession: nil)
        if ProcessInfo.processInfo.environment["LOCKIN_GRAPH_COMPLEX"] != nil {
            store.workGraph = WorkGraph()
            store.commitJournal { $0.setPlan([]) }
            try store.applyWorkImport(WorkGraphLayoutTests.fixture(), addToSession: true, targetSession: nil)
        }
        if let source = ProcessInfo.processInfo.environment["LOCKIN_GRAPH_DATA"] {
            let sourceDirectory = URL(fileURLWithPath: source)
            store.workGraph = try XCTUnwrap(WorkGraphStorage.load(from: sourceDirectory))
            store.journal = try Storage.load(from: sourceDirectory).journal
            store.normalizeSessionEntries()
            store.workImportMessage = nil
            let presentation = WorkPresentation(graph: store.sessionGraph, filter: .all, collapsed: [])
            assertLayoutInvariants(presentation, source)
            if let geometry = ProcessInfo.processInfo.environment["LOCKIN_GRAPH_GEOMETRY"] {
                let layout = presentation.layout
                let object: [String: Any] = [
                    "frames": layout.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
                    "groups": Dictionary(uniqueKeysWithValues: layout.groups.map { ($0.id, [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height]) }),
                    "routes": presentation.routes.mapValues { $0.points.map { [$0.x, $0.y] } }
                ]
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: URL(fileURLWithPath: geometry))
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
