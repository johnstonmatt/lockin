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
    func testBreakResumesRemainingWork() {
        let start = Date(timeIntervalSince1970: 1000)
        var session = FocusSession(profile: Profile(), mode: .timer, locked: false, now: start, duration: 600)
        session.beginBreak(at: start.addingTimeInterval(120))
        session.resume(at: start.addingTimeInterval(180))
        XCTAssertFalse(session.isBreak)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(180)), 480)
        XCTAssertEqual(session.usedBreakSeconds, 60)
    }
    func testUntimedBreakKeepsUntimedSession() {
        let start = Date(timeIntervalSince1970: 1000)
        var session = FocusSession(profile: Profile(), mode: .untimed, locked: false, now: start)
        session.beginBreak(at: start.addingTimeInterval(100))
        session.resume(at: start.addingTimeInterval(200))
        XCTAssertNil(session.deadline)
    }
    func testBreakAllowanceAndReset() {
        let start = Date(timeIntervalSince1970: 1000)
        var session = FocusSession(profile: Profile(), mode: .timer, locked: false, now: start)
        session.usedBreakSeconds = 590
        XCTAssertEqual(session.availableBreak(at: start.addingTimeInterval(60)), 10)
        session.usedBreakSeconds = 700
        XCTAssertEqual(session.availableBreak(at: start.addingTimeInterval(60)), 0)
        XCTAssertEqual(session.availableBreak(at: start.addingTimeInterval(3600)), 600)
    }
    func testScheduleWindowAndWeekdays() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 15))!
        var schedule = Schedule(profileID: UUID()); schedule.duration = 30
        XCTAssertNotNil(schedule.occurrence(at: monday, calendar: calendar))
        XCTAssertNil(schedule.occurrence(at: monday.addingTimeInterval(900), calendar: calendar))
        XCTAssertNil(schedule.occurrence(at: monday.addingTimeInterval(-901), calendar: calendar))
        schedule.weekdays = [1, 7]
        XCTAssertNil(schedule.occurrence(at: monday, calendar: calendar))
    }
    func testStateRoundTripRestoresLockedSession() throws {
        var state = SavedState()
        state.session = FocusSession(profile: state.profiles[0], mode: .timer, locked: true)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertEqual(restored.session?.deadline, state.session?.deadline)
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
}
