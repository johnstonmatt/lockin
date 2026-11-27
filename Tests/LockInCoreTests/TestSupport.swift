import Foundation
import LockInCore

extension Calendar {
    /// Gregorian in UTC, so day and hour boundaries don't depend on the machine running the tests.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

extension WorkImport {
    /// An import refreshed at a fixed time, so graphs built from it compare and encode the same on every run.
    static func fixture(id: String, url: String = "", nodeIDs: [String], edges: [WorkEdge]) -> WorkImport {
        WorkImport(id: id, url: url, nodeIDs: nodeIDs, edges: edges, refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
