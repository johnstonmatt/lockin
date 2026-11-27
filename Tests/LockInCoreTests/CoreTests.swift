import XCTest
@testable import LockInCore

final class CoreTests: XCTestCase {
    func testDomainBoundaryAndSubdomains() {
        XCTAssertTrue(WebsiteRule.matches("reddit.com", url: URL(string: "https://old.reddit.com/r/swift")!))
        XCTAssertFalse(WebsiteRule.matches("reddit.com", url: URL(string: "https://notreddit.com")!))
        XCTAssertFalse(WebsiteRule.matches("reddit.com", url: URL(string: "https://reddit.com.evil.example")!))
        XCTAssertTrue(WebsiteRule.matches("*.Reddit.com", url: URL(string: "https://reddit.com")!))
    }
    func testURLNormalizationAndPaths() {
        XCTAssertEqual(WebsiteRule.normalize(" https://YouTube.com/shorts "), "youtube.com/shorts")
        XCTAssertTrue(WebsiteRule.matches("youtube.com/shorts", url: URL(string: "https://www.youtube.com/shorts/123")!))
        XCTAssertFalse(WebsiteRule.matches("youtube.com/shorts", url: URL(string: "https://youtube.com/watch?v=123")!))
        XCTAssertNil(WebsiteRule.normalize("bad host.example"))
        XCTAssertNil(WebsiteRule.normalize("https://user:password@example.com"))
        XCTAssertNil(WebsiteRule.normalize("file:///tmp/a"))
    }
    func testRulePathsMatchWholeSegments() {
        let rule = "youtube.com/shorts"
        XCTAssertTrue(WebsiteRule.matches(rule, url: URL(string: "https://youtube.com/shorts")!))
        XCTAssertTrue(WebsiteRule.matches(rule, url: URL(string: "https://youtube.com/shorts/abc")!))
        XCTAssertFalse(WebsiteRule.matches(rule, url: URL(string: "https://youtube.com/shortstack")!))
        XCTAssertTrue(WebsiteRule.matches("example.com/docs/", url: URL(string: "https://example.com/docs/guide")!),
                      "a rule ending in / covers everything below it")
        XCTAssertFalse(WebsiteRule.matches("example.com/docs/", url: URL(string: "https://example.com/docsearch")!))
    }
    func testRulesWithAQueryMatchThatQueryOnly() {
        let rule = "youtube.com/watch?v=abc"
        XCTAssertTrue(WebsiteRule.matches(rule, url: URL(string: "https://www.youtube.com/watch?v=abc")!))
        XCTAssertFalse(WebsiteRule.matches(rule, url: URL(string: "https://www.youtube.com/watch?v=xyz")!))
        XCTAssertFalse(WebsiteRule.matches(rule, url: URL(string: "https://www.youtube.com/watch")!))
    }
    func testBlockListAndUpperCaseSchemes() {
        let rules = ["reddit.com", "youtube.com/shorts"]
        XCTAssertTrue(WebsiteRule.shouldBlock(URL(string: "https://www.reddit.com/r/swift")!, rules: rules, mode: .block))
        XCTAssertTrue(WebsiteRule.shouldBlock(URL(string: "https://youtube.com/shorts/1")!, rules: rules, mode: .block))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "https://youtube.com/watch?v=1")!, rules: rules, mode: .block))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "https://docs.example.com")!, rules: rules, mode: .block))
        XCTAssertTrue(WebsiteRule.shouldBlock(URL(string: "HTTPS://WWW.REDDIT.COM/r/swift")!, rules: rules, mode: .block))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "about:blank")!, rules: rules, mode: .block))
    }
    func testAllowListAndInternalPages() {
        XCTAssertTrue(WebsiteRule.shouldBlock(URL(string: "https://news.example.com")!, rules: ["docs.example.com"], mode: .allow))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "https://docs.example.com/help")!, rules: ["docs.example.com"], mode: .allow))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "about:blank")!, rules: [], mode: .allow))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "file:///tmp/blocked.html")!, rules: [], mode: .allow))
    }
    func testBlockPageCarriesFullyEncodedOriginalURL() {
        let original = "https://example.com/a b?x=1&y=2#frag"
        let destination = BlockPage.destination(base: "file:///App/blocked.html", original: original)
        XCTAssertEqual(destination, "file:///App/blocked.html?url=https%3A%2F%2Fexample.com%2Fa%20b%3Fx%3D1%26y%3D2%23frag")
        let parsed = URLComponents(string: destination)
        XCTAssertEqual(parsed?.queryItems?.count, 1)
        XCTAssertEqual(parsed?.queryItems?.first?.value, original)
    }
    func testTitlesFromLinks() {
        XCTAssertEqual(Todo.title(fromLink: "https://linear.app/supabase/issue/FUNC-1033/github-workflows-cannot-exceed-3600s"),
                       "FUNC-1033 github workflows cannot exceed 3600s")
        XCTAssertEqual(Todo.title(fromLink: "https://linear.app/supabase/issue/FUNC-1033"), "FUNC-1033")
        XCTAssertEqual(Todo.title(fromLink: "https://github.com/supabase/edge-runtime/pull/412"), "supabase/edge-runtime#412")
        XCTAssertEqual(Todo.title(fromLink: "https://github.com/supabase/edge-runtime/issues/9"), "supabase/edge-runtime#9")
        XCTAssertEqual(Todo.title(fromLink: "https://github.com/supabase/edge-runtime"), "supabase/edge-runtime")
        XCTAssertEqual(Todo.title(fromLink: "https://www.notion.so/supabase/Lock-In-Plan-0123456789abcdef0123456789abcdef"), "Lock In Plan")
        XCTAssertEqual(Todo.title(fromLink: "https://www.example.com/docs/setup/"), "example.com/docs/setup")
        XCTAssertEqual(Todo.title(fromLink: "https://example.com"), "example.com")
    }
}
