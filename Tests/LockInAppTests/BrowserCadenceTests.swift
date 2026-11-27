import XCTest
@testable import LockIn

final class BrowserCadenceTests: XCTestCase {
    func testForegroundChecksBetweenBackgroundSweeps() {
        var cadence = BrowserScanCadence()
        XCTAssertEqual(cadence.next(at: 10, browserIsFrontmost: true), true)
        XCTAssertNil(cadence.next(at: 10.1, browserIsFrontmost: true))
        XCTAssertEqual(cadence.next(at: 10.25, browserIsFrontmost: true), false)
        XCTAssertEqual(cadence.next(at: 11, browserIsFrontmost: true), false)
        XCTAssertEqual(cadence.next(at: 12, browserIsFrontmost: true), true)
    }
    func testBackgroundWorkDoesNotCauseFastBrowserPolling() {
        var cadence = BrowserScanCadence()
        XCTAssertEqual(cadence.next(at: 0, browserIsFrontmost: false), true)
        for time in [0.25, 0.5, 1, 1.75] {
            XCTAssertNil(cadence.next(at: time, browserIsFrontmost: false))
        }
        XCTAssertEqual(cadence.next(at: 2, browserIsFrontmost: false), true)
    }
    func testActivationAndResumeBypassNormalWait() {
        var cadence = BrowserScanCadence()
        _ = cadence.next(at: 0, browserIsFrontmost: true)
        XCTAssertEqual(cadence.next(at: 0.05, browserIsFrontmost: true, force: true), false)
        cadence.reset()
        XCTAssertEqual(cadence.next(at: 0.06, browserIsFrontmost: false), true)
    }
}

final class BlockerMessageTests: XCTestCase {
    func testPermissionMessagesNameTheBrowser() {
        for (id, name) in [("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Edge"),
                           ("com.vivaldi.Vivaldi", "Vivaldi"), ("company.thebrowser.Browser", "Arc")] {
            XCTAssertEqual(Blocker.permissionMessage(id, code: -1744), "\(name): permission not requested. Click Enable browser blocking.")
            XCTAssertTrue(Blocker.permissionMessage(id, code: -1743).contains("Enable Lock In → \(name) in System Settings"))
        }
        XCTAssertEqual(Blocker.permissionMessage("org.example.Unknown", code: -1), "org.example.Unknown: browser access failed (-1).")
    }
}
