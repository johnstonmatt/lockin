import XCTest
@testable import LockIn

final class CommandLineToolTests: XCTestCase {
    private var directory: URL!
    private var helper: URL!
    private var link: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        helper = directory.appendingPathComponent("Lock In.app/Contents/Helpers/lockin")
        link = directory.appendingPathComponent("bin/lockin")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testInstallLinksIntoTheApp() throws {
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .notInstalled)
        try CommandLineTool.install(helper: helper, link: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helper.path)
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .installed)
        XCTAssertNoThrow(try CommandLineTool.install(helper: helper, link: link), "installing twice is fine")
    }
    func testReplacesALinkToAnotherCopy() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/elsewhere/lockin")
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .linkedElsewhere("/elsewhere/lockin"))
        try CommandLineTool.install(helper: helper, link: link)
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .installed)
    }
    func testNeverOverwritesAFile() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: link)
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .blocked)
        XCTAssertThrowsError(try CommandLineTool.install(helper: helper, link: link))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "mine")
    }
    func testUnavailableWithoutTheHelper() {
        XCTAssertEqual(CommandLineTool.status(helper: nil, link: link), .unavailable)
        XCTAssertThrowsError(try CommandLineTool.install(helper: nil, link: link))
    }
}
