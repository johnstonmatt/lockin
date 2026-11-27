import XCTest
import LockInCore
@testable import LockIn

final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

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
        throw LockInError("unexpected import")
    }, enrichGitHub: { seed in
        XCTFail("unexpected import of \(seed.snapshot.id)")
        throw LockInError("unexpected import")
    })

    /// A store running a session planned with `tasks`.
    @MainActor func startedStore(tasks: [String] = ["Work"], hours: Double? = nil, hardcore: Bool = false) -> Store {
        let store = makeStore()
        store.journal.draft = tasks.map { Todo(title: $0) }
        if let hours { store.journal.hours = hours }
        store.lockSession = hardcore
        store.start()
        return store
    }

    /// Replaces quitting the app with a count of quits.
    @MainActor func countQuits(of store: Store) -> () -> Int {
        let quits = Box(0)
        store.terminate = { quits.value += 1 }
        return { quits.value }
    }

    /// Moves the clock on and lets the store catch up, as its timer would.
    @MainActor func advance(_ store: Store, by seconds: TimeInterval) {
        clock.advance(by: seconds)
        store.tick()
    }
}
