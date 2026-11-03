import Foundation

public struct Todo: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title = ""
    /// Optional web link for the task: a Linear issue, GitHub issue or PR, Notion page, or any other URL.
    public var link = ""
    public var completed = false
    public var rollForward = false
    public var sourceTodoID: UUID?
    /// `link` keeps the "linearURL" key from when only Linear links were allowed, so existing journals load unchanged.
    private enum CodingKeys: String, CodingKey { case id, title, link = "linearURL", completed, rollForward, sourceTodoID }
    public init(title: String = "") { self.title = title }
    public static let linkRequirement = "Use a full web link, starting with https://"
    /// Blank, or an http(s) URL with a host.
    public static func isValidLink(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
    public var validLink: Bool { Self.isValidLink(link) }
    /// The link as a URL, when one is set and valid.
    public var linkURL: URL? { link.isEmpty || !validLink ? nil : URL(string: link) }
    public var linkService: LinkService? { linkURL.flatMap(LinkService.init(url:)) }
    /// What the link is shown as: the service name for Linear, GitHub and Notion, otherwise the site's host.
    public var linkLabel: String? {
        guard let url = linkURL else { return nil }
        if let service = linkService { return service.label }
        let host = url.host ?? link
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    public var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A copy with user-entered fields applied and trimmed; identity and lineage are kept.
    public func with(title: String, link: String) -> Todo {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}
/// Services a task link is recognized as, by host.
public enum LinkService: String, CaseIterable, Sendable {
    case linear, github, notion
    public var label: String {
        switch self {
        case .linear: return "Linear"
        case .github: return "GitHub"
        case .notion: return "Notion"
        }
    }
    private var domains: [String] {
        switch self {
        case .linear: return ["linear.app"]
        case .github: return ["github.com"]
        case .notion: return ["notion.so", "notion.site"]
        }
    }
    public init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        let match = Self.allCases.first { $0.domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        guard let match else { return nil }
        self = match
    }
}
public enum WorkPhase: String, Codable, CaseIterable, Sendable { case work, `break`, pause }
public struct WorkInterval: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var kind: WorkPhase
    public var start: Date
    public var end: Date?
    public var reason: String?
    public func seconds(at now: Date) -> Double { max(0, (end ?? now).timeIntervalSince(start)) }
}
public struct WorkLog: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var startedAt: Date
    public var endedAt: Date?
    public var targetSeconds: Double
    public var todos: [Todo]
    public var intervals: [WorkInterval]
    public var finishedNaturally = false
    /// Why the session was ended before reaching its target; nil for natural finishes.
    public var endReason: String?
    public var reviewed = false
    public var phase: WorkPhase? { endedAt == nil ? intervals.last?.kind : nil }
    public init(todos: [Todo], targetSeconds: Double, now: Date) {
        self.todos = todos; self.targetSeconds = targetSeconds; startedAt = now
        intervals = [WorkInterval(kind: .work, start: now)]
    }
    public func seconds(_ phase: WorkPhase, at now: Date) -> Double {
        intervals.filter { $0.kind == phase }.reduce(0) { $0 + $1.seconds(at: now) }
    }
    public func remaining(at now: Date) -> Double { max(0, targetSeconds - seconds(.work, at: now)) }
    public func breakBalance(at now: Date) -> Double { max(0, seconds(.work, at: now) / 12 - seconds(.break, at: now)) }
    public mutating func transition(to phase: WorkPhase, at now: Date, reason: String? = nil) {
        guard endedAt == nil, self.phase != phase else { return }
        intervals[intervals.count - 1].end = now
        intervals.append(WorkInterval(kind: phase, start: now, reason: reason))
    }
    public mutating func pause(reason: String, at now: Date) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, endedAt == nil, phase != .pause else { return false }
        transition(to: .pause, at: now, reason: trimmed); return true
    }
    public mutating func takeBreak(at now: Date) -> Bool {
        guard phase == .work, breakBalance(at: now) >= 1 else { return false }
        transition(to: .break, at: now); return true
    }
    public mutating func finish(at now: Date, natural: Bool) {
        guard endedAt == nil else { return }
        intervals[intervals.count - 1].end = now; endedAt = now; finishedNaturally = natural
    }
    /// Ends an open session before its target, e.g. to start a new day. Requires a nonblank explanation.
    public mutating func endEarly(reason: String, at now: Date) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, endedAt == nil else { return false }
        endReason = trimmed
        finish(at: now, natural: false); return true
    }
    /// The last moment of work or break, so an overnight pause doesn't make the review show the wrong day.
    public var lastActiveAt: Date {
        intervals.last { $0.kind != .pause }.map { $0.end ?? $0.start } ?? endedAt ?? startedAt
    }
    /// Exact boundaries avoid charging excess break time or overcounting work after a delayed tick.
    public mutating func advance(at now: Date) {
        guard endedAt == nil, let current = intervals.last else { return }
        if phase == .break {
            let allowance = breakBalance(at: current.start)
            let end = current.start.addingTimeInterval(allowance)
            if now >= end { transition(to: .work, at: end) }
        }
        if phase == .work, let current = intervals.last {
            let end = current.start.addingTimeInterval(remaining(at: current.start))
            if now >= end { finish(at: end, natural: true) }
        }
    }
    public var rolledTodos: [Todo] {
        todos.filter(\.rollForward).map { old in
            var todo = Todo(title: old.title); todo.link = old.link; todo.sourceTodoID = old.id
            return todo
        }
    }
}
public struct JournalState: Codable {
    public var draft: [Todo] = [Todo()]
    public var hours = 2.0
    public var sessions: [WorkLog] = []
    public var pendingReviewID: UUID?
    /// The pause interval created by `lockin://update`; the next launch resumes work only if it is still the current interval.
    public var resumeAfterUpdateID: UUID?
    public init() {}
}

/// Human-readable YAML. JSON-quoted scalar strings are valid YAML and safely escape user text.
public enum SessionYAML {
    private static func quoted(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
    private static func date(_ value: Date?) -> String {
        guard let value else { return "null" }
        return quoted(ISO8601DateFormatter().string(from: value))
    }
    public static func encode(_ log: WorkLog, at now: Date) -> String {
        // Version 2: a task's `linear_url` became `link`, plus `link_service`.
        var lines = ["schema_version: 2", "id: \(quoted(log.id.uuidString))", "started_at: \(date(log.startedAt))", "ended_at: \(date(log.endedAt))", "target_work_seconds: \(log.targetSeconds)", "finished_naturally: \(log.finishedNaturally)", "end_reason: \(log.endReason.map(quoted) ?? "null")", "reviewed: \(log.reviewed)", "work_seconds: \(log.seconds(.work, at: now))", "break_seconds: \(log.seconds(.break, at: now))", "pause_seconds: \(log.seconds(.pause, at: now))", "earned_break_seconds: \(log.seconds(.work, at: now) / 12)", "remaining_break_seconds: \(log.breakBalance(at: now))", "todos:\(log.todos.isEmpty ? " []" : "")"]
        for todo in log.todos {
            lines += ["  - id: \(quoted(todo.id.uuidString))", "    title: \(quoted(todo.title))", "    link: \(todo.link.isEmpty ? "null" : quoted(todo.link))", "    link_service: \(todo.linkService.map { quoted($0.rawValue) } ?? "null")", "    completed: \(todo.completed)", "    roll_into_next_session: \(todo.rollForward)", "    source_todo_id: \(todo.sourceTodoID.map { quoted($0.uuidString) } ?? "null")"]
        }
        lines.append("intervals:")
        for interval in log.intervals {
            lines += ["  - kind: \(interval.kind.rawValue)", "    started_at: \(date(interval.start))", "    ended_at: \(date(interval.end))", "    duration_seconds: \(interval.seconds(at: now))", "    reason: \(interval.reason.map(quoted) ?? "null")"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
