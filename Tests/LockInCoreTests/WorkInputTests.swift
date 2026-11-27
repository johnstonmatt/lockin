import XCTest
@testable import LockInCore

final class WorkInputTests: XCTestCase {
    func testWorkInput() throws {
        XCTAssertEqual(try WorkInput("Write docs"), WorkInput(title: "Write docs"))
        XCTAssertEqual(try WorkInput("https://linear.app/s/issue/FUNC-1/fix-it"), WorkInput(link: "https://linear.app/s/issue/FUNC-1/fix-it"))
        XCTAssertEqual(try WorkInput("Fix it - https://linear.app/s/issue/FUNC-1"), WorkInput(title: "Fix it", link: "https://linear.app/s/issue/FUNC-1"))
        XCTAssertEqual(try WorkInput("Ops - rotate keys - https://x.com/a"), WorkInput(title: "Ops - rotate keys", link: "https://x.com/a"),
                       "titles can contain the separator")
        XCTAssertEqual(try WorkInput("Before - after"), WorkInput(title: "Before - after"))
        XCTAssertThrowsError(try WorkInput("Fix it - https://"), "a mistyped link isn't folded into the title")
        XCTAssertEqual(WorkInput(link: "https://linear.app/s/issue/FUNC-1/fix-it").newTitle, "FUNC-1 fix it")
    }

    func testValidationAndImportClassification() throws {
        for text in ["", "  ", "https://", "www.example.com", "Task - https://", "ftp://example.com"] {
            XCTAssertThrowsError(try WorkInput(text), text)
        }
        let issue = try WorkInput(" ENG-1 ")
        XCTAssertEqual(issue.importURL, "ENG-1")
        XCTAssertEqual(issue.identity, "linear:ENG-1")
        XCTAssertEqual(try WorkInput("PR - https://github.com/org/repo/pull/12").importURL, "https://github.com/org/repo/pull/12")
        XCTAssertNil(try WorkInput("Docs - https://example.com/docs").importURL)
        XCTAssertEqual(WorkInput(title: " ", link: " https://example.com "), WorkInput(link: "https://example.com"))
        XCTAssertThrowsError(try WorkInput(title: "Docs", link: "not-a-link").validate())
    }
}
