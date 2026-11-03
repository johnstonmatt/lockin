import Foundation

public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case timer = "Timer", pomodoro = "Pomodoro", untimed = "Open ended"
}
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
    public var workMinutes = 50
    public var breakMinutes = 10
    public var breakAllowanceMinutes = 10
    public var breakWindowHours = 1
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
public struct FocusSession: Codable, Sendable {
    public var profile: Profile
    public var mode: SessionMode
    public var locked: Bool
    public var startedAt: Date
    public var phaseStartedAt: Date
    public var deadline: Date?
    public var isBreak = false
    public var round = 1
    public var remainingWork: TimeInterval?
    public var breakWindowStartedAt: Date
    public var usedBreakSeconds: TimeInterval = 0
    public init(profile: Profile, mode: SessionMode, locked: Bool, now: Date = Date(), duration: TimeInterval? = nil) {
        self.profile = profile; self.mode = mode; self.locked = locked
        startedAt = now; phaseStartedAt = now; breakWindowStartedAt = now
        deadline = mode == .untimed ? nil : now.addingTimeInterval(duration ?? Double(profile.workMinutes * 60))
    }
    public func remaining(at date: Date) -> TimeInterval { max(0, deadline?.timeIntervalSince(date) ?? date.timeIntervalSince(phaseStartedAt)) }
    public mutating func beginBreak(at date: Date) {
        remainingWork = deadline.map { max(0, $0.timeIntervalSince(date)) }
        isBreak = true; phaseStartedAt = date
        deadline = date.addingTimeInterval(Double(profile.breakMinutes * 60))
    }
    public mutating func resume(at date: Date) {
        usedBreakSeconds += max(0, date.timeIntervalSince(phaseStartedAt))
        isBreak = false; phaseStartedAt = date
        deadline = mode == .untimed ? nil : date.addingTimeInterval(remainingWork ?? Double(profile.workMinutes * 60))
        remainingWork = nil
    }
    public mutating func availableBreak(at date: Date) -> TimeInterval {
        if date.timeIntervalSince(breakWindowStartedAt) >= Double(profile.breakWindowHours * 3600) {
            breakWindowStartedAt = date; usedBreakSeconds = 0
        }
        return max(0, Double(profile.breakAllowanceMinutes * 60) - usedBreakSeconds)
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
