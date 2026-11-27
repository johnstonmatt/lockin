import Foundation
import LockInCore

// Fixtures shared by every test target.

extension Calendar {
    /// Gregorian in UTC, so day and hour boundaries don't depend on the machine running the tests.
    public static var utc: Calendar { calendar(in: "UTC") }

    public static func calendar(in timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }
}

extension WorkImport {
    /// An import refreshed at a fixed time, so graphs built from it compare and encode the same on every run.
    public static func fixture(id: String, url: String = "", nodeIDs: [String], edges: [WorkEdge]) -> WorkImport {
        WorkImport(id: id, url: url, nodeIDs: nodeIDs, edges: edges, refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

extension WorkGraph {
    /// A graph holding just `result`.
    public init(merging result: WorkImportResult) {
        self.init()
        merge(result)
    }
}

extension WorkImporter {
    /// Answers every Linear import with `result`, leaving GitHub details as they are.
    public static func returning(_ result: WorkImportResult) -> WorkImporter {
        WorkImporter(fetchLinear: { _ in result }, enrichGitHub: { $0 })
    }
}
