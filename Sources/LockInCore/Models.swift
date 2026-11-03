import Foundation

public enum BlockingMode: String, Codable, CaseIterable, Sendable {
    case block = "Block list", allow = "Allow list"
}
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name = "Deep work"
    public var symbol = "mountain.2"
    public var websites = ["reddit.com", "youtube.com", "x.com", "instagram.com", "facebook.com"]
    public var applications: [BlockedApp] = []
    public var blockingMode: BlockingMode = .block
    public var hooks: [String: String] = [:]
    public var passwordSalt: String?
    public var passwordHash: String?
    public init(name: String = "Deep work", symbol: String = "mountain.2") {
        self.name = name; self.symbol = symbol
    }
}
public struct BlockedApp: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String
    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}
public struct Schedule: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var profileID: UUID
    public var enabled = true
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var hour = 9
    public var minute = 0
    public var duration = 50
    public var locked = false
    public init(profileID: UUID) { self.profileID = profileID }
    public func occurrence(at date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, weekdays.contains(calendar.component(.weekday, from: date)),
              let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date),
              date >= start, date < start.addingTimeInterval(Double(duration) * 60) else { return nil }
        return start
    }
}
public struct FocusRecord: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var profileName: String
    public var start: Date
    public var end: Date
    public var completed: Bool
    public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public init(profileName: String, start: Date, end: Date, completed: Bool) {
        self.profileName = profileName; self.start = start; self.end = end; self.completed = completed
    }
}
/// Enforcement settings for the running session. Phase and timing live in the session's `WorkLog`.
/// Keys written by older builds (mode, deadline, Pomodoro counters) are ignored when decoding.
public struct FocusSession: Codable, Sendable {
    /// A snapshot, so profile edits made during a session don't change what's being enforced.
    public var profile: Profile
    public var locked: Bool
    public var startedAt: Date
    public init(profile: Profile, locked: Bool, startedAt: Date) {
        self.profile = profile; self.locked = locked; self.startedAt = startedAt
    }
}
public struct SavedState: Codable {
    public var profiles = [Profile(name: "Focus")]
    public var selectedProfileID: UUID?
    public var schedules: [Schedule] = []
    public var records: [FocusRecord] = []
    public var session: FocusSession?
    public var firedSchedules: [String: Date] = [:]
    public init() {}
}
