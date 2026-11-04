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
/// Enforcement settings for the running session. Phase and timing live in the session's `WorkLog`.
/// Keys written by older builds (startedAt, mode, deadline, Pomodoro counters) are ignored when decoding.
public struct FocusSession: Codable, Equatable, Sendable {
    /// A snapshot, so profile edits made during a session don't change what's being enforced.
    public var profile: Profile
    public var locked: Bool
    public init(profile: Profile, locked: Bool) { self.profile = profile; self.locked = locked }
}
/// Keys written by older builds (schedules, firedSchedules, records) are ignored when decoding.
public struct SavedState: Codable, Equatable {
    public var profiles = [Profile(name: "Focus")]
    public var selectedProfileID: UUID?
    public var session: FocusSession?
    public init() {}
}
