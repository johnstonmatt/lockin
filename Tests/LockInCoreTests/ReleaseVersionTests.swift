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
