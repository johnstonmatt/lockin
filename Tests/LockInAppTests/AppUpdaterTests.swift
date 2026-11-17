import XCTest
@testable import LockIn

@MainActor final class AppUpdaterTests: XCTestCase {
    func testNewerReleaseIsOfferedWithoutInstalling() async {
        var installations = 0
        let updater = AppUpdater(currentVersion: "0.9.0", helper: URL(fileURLWithPath: "/unused"),
                                 fetchLatest: { "0.10.0" }, installLatest: { installations += 1; return "Installed" })
        await updater.check()
        XCTAssertEqual(updater.availableVersion, "0.10.0")
        XCTAssertEqual(installations, 0)
        XCTAssertFalse(updater.busy)
        await updater.install(locked: true)
        XCTAssertEqual(installations, 0)
        XCTAssertNotNil(updater.availableVersion)
        await updater.install(locked: false)
        XCTAssertEqual(installations, 1)
        XCTAssertNil(updater.availableVersion)
        XCTAssertEqual(updater.status, "Installed")
    }

    func testSameOrNewerInstalledVersionDoesNotOfferUpdate() async {
        for installed in ["1.0", "1.1.0"] {
            let updater = AppUpdater(currentVersion: installed, fetchLatest: { "1.0.0" })
            await updater.check()
            XCTAssertNil(updater.availableVersion)
            XCTAssertTrue(updater.status.contains("up to date"))
        }
    }

    func testFailedCheckClearsStaleOfferAndCanBeRetried() async {
        var fail = false
        let updater = AppUpdater(currentVersion: "1.0.0", fetchLatest: {
            if fail { throw URLError(.notConnectedToInternet) }
            return "1.1.0"
        })
        await updater.check()
        fail = true
        await updater.check()
        XCTAssertNil(updater.availableVersion)
        XCTAssertFalse(updater.busy)
        XCTAssertTrue(updater.status.contains("Couldn't check"))
        fail = false
        await updater.check()
        XCTAssertEqual(updater.availableVersion, "1.1.0")
    }

    func testInstallFailureKeepsOfferForRetry() async {
        let updater = AppUpdater(currentVersion: "1.0", helper: URL(fileURLWithPath: "/unused"),
                                 fetchLatest: { "1.1" }, installLatest: { throw URLError(.networkConnectionLost) })
        await updater.check()
        await updater.install(locked: false)
        XCTAssertFalse(updater.busy)
        XCTAssertEqual(updater.availableVersion, "1.1")
        XCTAssertTrue(updater.status.contains("Couldn't install"))
    }

    func testMissingHelperCannotInstall() async {
        var installed = false
        let updater = AppUpdater(currentVersion: "1.0", helper: nil,
                                 fetchLatest: { "1.1" }, installLatest: { installed = true; return "" })
        await updater.check()
        await updater.install(locked: false)
        XCTAssertFalse(updater.canInstall)
        XCTAssertFalse(installed)
    }

    func testDevelopmentBuildDoesNotFetch() async {
        var fetched = false
        let updater = AppUpdater(currentVersion: nil, fetchLatest: { fetched = true; return "1.0" })
        await updater.check()
        XCTAssertFalse(fetched)
        XCTAssertNil(updater.availableVersion)
        XCTAssertTrue(updater.status.contains("development build"))
    }

    func testBundledHelperReceivesUpgradeAndReportsFailureOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("lockin")
        try Data("#!/bin/sh\nprintf 'Command: %s\\n' \"$1\"\nprintf 'Installation refused\\n' >&2\nexit 1\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let updater = AppUpdater(currentVersion: "1.0", helper: helper, fetchLatest: { "1.1" })
        await updater.check()
        await updater.install(locked: false)
        XCTAssertTrue(updater.status.contains("Command: upgrade"))
        XCTAssertTrue(updater.status.contains("Installation refused"))
        XCTAssertEqual(updater.availableVersion, "1.1")
        XCTAssertFalse(updater.busy)
    }
}
