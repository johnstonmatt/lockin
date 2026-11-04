import Foundation

/// The raw values are the labels shown in the app; files use `ProfileRecord.Mode`.
public enum BlockingMode: String, CaseIterable, Sendable {
    case block = "Block list", allow = "Allow list"
}
public struct Profile: Identifiable, Equatable, Sendable {
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
public struct BlockedApp: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String
    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}
/// Enforcement settings for the running session. Phase and timing live in the session's `WorkLog`.
public struct FocusSession: Equatable, Sendable {
    /// A snapshot, so profile edits made during a session don't change what's being enforced.
    public var profile: Profile
    public var locked: Bool
    public init(profile: Profile, locked: Bool) { self.profile = profile; self.locked = locked }
}
/// Profiles and the running session's enforcement, saved in settings.json.
public struct SavedState: Equatable {
    public var profiles = [Profile(name: "Focus")]
    public var selectedProfileID: UUID?
    public var session: FocusSession?
    public init() {}
}
