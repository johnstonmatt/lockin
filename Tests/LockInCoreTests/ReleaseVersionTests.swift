import XCTest
import LockInCore

final class ReleaseVersionTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertEqual(ReleaseVersion.compare("0.10.0", "0.9.1"), .orderedDescending)
        XCTAssertEqual(ReleaseVersion.compare("0.3.0", "0.4.0"), .orderedAscending)
        XCTAssertEqual(ReleaseVersion.compare("1.0", "1.0.0"), .orderedSame)
    }

    func testVersionFromTag() {
        XCTAssertEqual(ReleaseVersion.version(fromTag: "v1.2.4"), "1.2.4")
        XCTAssertEqual(ReleaseVersion.version(fromTag: "1.2.4"), "1.2.4")
        for tag in ["", "v", "v1..2", "v1.2.4-beta", "latest"] {
            XCTAssertNil(ReleaseVersion.version(fromTag: tag), tag)
        }
    }
}

final class LatestReleaseTests: XCTestCase {
    func testReadsTagVersionAndAppAsset() throws {
        let json = """
            {"tag_name": "v1.3.0", "assets": [
              {"name": "LockIn-v1.3.0-macos-arm64.zip", "browser_download_url": "https://example.com/app.zip"},
              {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}]}
            """
        let release = try ReleaseVersion.latestRelease(from: Data(json.utf8), statusCode: 200)
        XCTAssertEqual(release.version, "1.3.0")
        XCTAssertEqual(release.appAsset?.url, URL(string: "https://example.com/app.zip"))
    }

    func testRejectsFailuresAndBadTags() {
        XCTAssertThrowsError(try ReleaseVersion.latestRelease(from: Data("{}".utf8), statusCode: 404))
        XCTAssertThrowsError(try ReleaseVersion.latestRelease(from: Data(#"{"tag_name": "latest"}"#.utf8), statusCode: 200))
        XCTAssertThrowsError(try ReleaseVersion.latestRelease(from: Data("not json".utf8), statusCode: 200))
    }
}
