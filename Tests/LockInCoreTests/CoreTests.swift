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
    func testAllowListAndInternalPages() {
        XCTAssertTrue(WebsiteRule.shouldBlock(URL(string: "https://news.example.com")!, rules: ["docs.example.com"], mode: .allow))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "https://docs.example.com/help")!, rules: ["docs.example.com"], mode: .allow))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "about:blank")!, rules: [], mode: .allow))
        XCTAssertFalse(WebsiteRule.shouldBlock(URL(string: "file:///tmp/blocked.html")!, rules: [], mode: .allow))
    }
    func testStateRoundTripRestoresLockedSession() throws {
        var state = SavedState()
        state.session = FocusSession(profile: state.profiles[0], locked: true)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertTrue(restored.session!.locked)
        XCTAssertEqual(restored.profiles, state.profiles)
    }
    func testBlockPageCarriesFullyEncodedOriginalURL() {
        let original = "https://example.com/a b?x=1&y=2#frag"
        let destination = BlockPage.destination(base: "file:///App/blocked.html", original: original)
        XCTAssertEqual(destination, "file:///App/blocked.html?url=https%3A%2F%2Fexample.com%2Fa%20b%3Fx%3D1%26y%3D2%23frag")
        let parsed = URLComponents(string: destination)
        XCTAssertEqual(parsed?.queryItems?.count, 1)
        XCTAssertEqual(parsed?.queryItems?.first?.value, original)
    }
    /// State written before the Pomodoro-era fields, schedules and focus records were removed must still load, including a running session.
    func testDecodesStateWrittenByOlderBuilds() throws {
        let profileID = UUID().uuidString
        let profile = """
        {"id":"\(profileID)","name":"Focus","symbol":"mountain.2","websites":["reddit.com"],"applications":[],"blockingMode":"Block list",
         "workMinutes":50,"breakMinutes":10,"breakAllowanceMinutes":10,"breakWindowHours":1,"hooks":{}}
        """
        let json = """
        {"profiles":[\(profile)],"selectedProfileID":"\(profileID)","schedules":[],"records":[{"id":"\(UUID())","profileName":"Focus","start":0,"end":60,"completed":true}],"firedSchedules":{},
         "session":{"profile":\(profile),"mode":"Timer","locked":true,"startedAt":1000,"phaseStartedAt":1000,"deadline":4600,
                    "isBreak":false,"round":1,"breakWindowStartedAt":1000,"usedBreakSeconds":0}}
        """
        let state = try JSONDecoder().decode(SavedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.profiles.first?.websites, ["reddit.com"])
        XCTAssertEqual(state.session?.locked, true)
    }
}
