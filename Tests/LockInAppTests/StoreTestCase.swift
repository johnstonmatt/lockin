import XCTest
import LockInCore
@testable import LockIn

/// A clock tests move by hand, so elapsed time never depends on how long a test takes.
final class TestClock: @unchecked Sendable {
    /// Whole seconds: saved timestamps keep sub-second precision, so a fractional start would reload slightly off.
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A test with its own temporary ~/.lockin and clock. Each `makeStore()` reads that directory afresh, so calling it
/// again simulates relaunching the app.
class StoreTestCase: XCTestCase {
    var directory: URL!
    var clock: TestClock!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        clock = TestClock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Never answers the real CLI, blocks browsers or ticks on its own; network imports fail the test unless a call
    /// passes its own importer.
    @MainActor func makeStore(channel: RemoteChannel? = nil, importer: WorkImporter = StoreTestCase.failingImporter) -> Store {
        let clock = clock!
        return Store(directory: directory, runTimer: false, enforceBlocking: false, channel: channel, importer: importer,
                     clock: { clock.now })
    }

    static let failingImporter = WorkImporter(fetchLinear: { input in
        XCTFail("unexpected import of \(input)")
        throw WorkImportError("unexpected import")
    }, enrichGitHub: { seed in
        XCTFail("unexpected import of \(seed.snapshot.id)")
        throw WorkImportError("unexpected import")
    })

    /// Moves the clock on and lets the store catch up, as its timer would.
    @MainActor func advance(_ store: Store, by seconds: TimeInterval) {
        clock.advance(by: seconds)
        store.tick()
    }
}

extension WorkImport {
    /// An import refreshed at a fixed time, so graphs built from it compare equal however long the test runs.
    static func fixture(id: String, url: String = "", nodeIDs: [String], edges: [WorkEdge]) -> WorkImport {
        WorkImport(id: id, url: url, nodeIDs: nodeIDs, edges: edges, refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
