import Foundation

extension String {
    /// Trimmed of surrounding whitespace and newlines, as user-entered text is saved.
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isBlank: Bool { trimmed.isEmpty }
}

public struct Todo: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title = ""
    /// Optional web link for the task: a Linear issue, GitHub issue or PR, Notion page, or any other URL.
    public var link = ""
    public var completed = false
    public var rollForward = false
    public var sourceTodoID: UUID?
    public init(title: String = "") { self.title = title }
    public static let linkRequirement = "Use a full web link, starting with https://"
    /// Blank, or an http(s) URL with a host. Surrounding whitespace is ignored, as it is trimmed on save.
    public static func isValidLink(_ text: String) -> Bool {
        if text.isBlank { return true }
        guard let url = URL(string: text.trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
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
        return Self.site(url.host ?? link)
    }
    /// A host without its "www." prefix.
    private static func site(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
    /// A title for a task given only a link, read from the URL itself (no network access):
    /// "FUNC-1033 github workflows cannot exceed 3600s" for a Linear issue, "owner/repo#12" for a GitHub PR or issue,
    /// the page name for Notion, and the host and path for anything else.
    public static func title(fromLink text: String) -> String {
        guard let url = URL(string: text.trimmed), let host = url.host, !host.isEmpty else { return text.trimmed }
        let parts = url.pathComponents.filter { $0 != "/" }
        func words(_ slug: String) -> String { slug.replacingOccurrences(of: "-", with: " ").trimmed }
        switch LinkService(url: url) {
        case .linear?:
            if let issue = parts.firstIndex(of: "issue"), issue + 1 < parts.count {
                let key = parts[issue + 1]
                let slug = issue + 2 < parts.count ? words(parts[issue + 2]) : ""
                return slug.isEmpty ? key : "\(key) \(slug)"
            }
        case .github?:
            if parts.count >= 4, ["pull", "issues"].contains(parts[2]) { return "\(parts[0])/\(parts[1])#\(parts[3])" }
            if !parts.isEmpty { return parts.joined(separator: "/") }
        case .notion?:
            // Page URLs end in the page's 32-character hex ID, e.g. "Lock-In-Plan-0123…cdef".
            if var page = parts.last {
                if let id = page.range(of: "-?[0-9a-f]{32}$", options: .regularExpression) { page.removeSubrange(id) }
                if !words(page).isEmpty { return words(page) }
            }
        case nil: break
        }
        let name = site(host)
        return parts.isEmpty ? name : name + "/" + parts.joined(separator: "/")
    }
    public var hasTitle: Bool { !title.isBlank }
    /// Has a title and a usable (or no) link: what a task needs before it can be saved.
    public var isValid: Bool { hasTitle && validLink }
    /// A copy with user-entered fields applied and trimmed; identity and lineage are kept.
    public func with(title: String, link: String) -> Todo {
        var copy = self
        copy.title = title.trimmed
        copy.link = link.trimmed
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
/// `overtime` is work done after the target is reached; it's recorded separately but counts as work.
public enum WorkPhase: String, Codable, CaseIterable, Sendable {
    case work, overtime, `break`, pause
    /// Work and overtime: time that's focused, blocked and earns break credit.
    public var isFocused: Bool { self == .work || self == .overtime }
}
public struct WorkInterval: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: WorkPhase
    public var start: Date
    public var end: Date?
    public var reason: String?
    /// Work added afterwards with `lockin backfill` rather than timed live.
    public var backfilled = false
    public func seconds(at now: Date) -> Double { max(0, (end ?? now).timeIntervalSince(start)) }
}
/// Something that happened during a session, in your words: "Deployed to staging", "Interrupted by a call".
public struct SessionEvent: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var at: Date
    public var text: String
    public init(at: Date, text: String) { self.at = at; self.text = text }
}
public struct WorkLog: Identifiable, Equatable, Sendable {
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
    /// Notes recorded during the session with `lockin event add`, in the order they were added.
    public var events: [SessionEvent] = []
    public var phase: WorkPhase? { endedAt == nil ? intervals.last?.kind : nil }
    public init(todos: [Todo], targetSeconds: Double, now: Date) {
        self.todos = todos; self.targetSeconds = targetSeconds; startedAt = now
        intervals = [WorkInterval(kind: .work, start: now)]
    }
    public func seconds(_ phase: WorkPhase, at now: Date) -> Double {
        intervals.filter { $0.kind == phase }.reduce(0) { $0 + $1.seconds(at: now) }
    }
    /// Work and overtime together.
    public func worked(at now: Date) -> Double { seconds(.work, at: now) + seconds(.overtime, at: now) }
    /// Work left before the target. Overtime doesn't count toward it: it only starts once this reaches zero.
    public func remaining(at now: Date) -> Double { max(0, targetSeconds - seconds(.work, at: now)) }
    public func targetReached(at now: Date) -> Bool { remaining(at: now) <= 0 }
    /// The phase to work in: regular work until the target is reached, overtime after.
    public func focusPhase(at now: Date) -> WorkPhase { targetReached(at: now) ? .overtime : .work }
    public func breakBalance(at now: Date) -> Double { max(0, worked(at: now) / 12 - seconds(.break, at: now)) }
    public mutating func transition(to phase: WorkPhase, at now: Date, reason: String? = nil) {
        guard endedAt == nil, self.phase != phase else { return }
        intervals[intervals.count - 1].end = now
        intervals.append(WorkInterval(kind: phase, start: now, reason: reason))
    }
    public mutating func pause(reason: String, at now: Date) -> Bool {
        guard !reason.isBlank, endedAt == nil, phase != .pause else { return false }
        transition(to: .pause, at: now, reason: reason.trimmed); return true
    }
    public mutating func takeBreak(at now: Date) -> Bool {
        guard phase?.isFocused == true, breakBalance(at: now) >= 1 else { return false }
        transition(to: .break, at: now); return true
    }
    public mutating func finish(at now: Date, natural: Bool) {
        guard endedAt == nil else { return }
        intervals[intervals.count - 1].end = now; endedAt = now; finishedNaturally = natural
    }
    /// Ends a session that has reached its target. Recorded as a natural finish, overtime included.
    public mutating func complete(at now: Date) -> Bool {
        guard endedAt == nil, targetReached(at: now) else { return false }
        finish(at: now, natural: true); return true
    }
    /// Records an event on an open session. Requires nonblank text, which is saved trimmed.
    public mutating func addEvent(_ text: String, at now: Date) -> Bool {
        guard !text.isBlank, endedAt == nil else { return false }
        events.append(SessionEvent(at: now, text: text.trimmed)); return true
    }
    /// Ends an open session before its target, e.g. to start a new day. Requires a nonblank explanation.
    public mutating func endEarly(reason: String, at now: Date) -> Bool {
        guard !reason.isBlank, endedAt == nil else { return false }
        endReason = reason.trimmed
        finish(at: now, natural: false); return true
    }
    /// The last moment of work or break, so an overnight pause doesn't make the review show the wrong day.
    public var lastActiveAt: Date {
        intervals.last { $0.kind != .pause }.map { $0.end ?? $0.start } ?? endedAt ?? startedAt
    }
    /// Ends a spent break and moves work into overtime once the target is reached. Sessions never end on their own.
    /// Exact boundaries avoid charging excess break time or misattributing work after a delayed tick.
    public mutating func advance(at now: Date) {
        guard endedAt == nil, let current = intervals.last else { return }
        if phase == .break {
            let end = current.start.addingTimeInterval(breakBalance(at: current.start))
            if now >= end { transition(to: focusPhase(at: end), at: end) }
        }
        if phase == .work, let current = intervals.last {
            let end = current.start.addingTimeInterval(remaining(at: current.start))
            if now >= end { transition(to: .overtime, at: end) }
        }
    }
    public var rolledTodos: [Todo] {
        todos.filter(\.rollForward).map { old in
            var todo = Todo(title: old.title); todo.link = old.link; todo.sourceTodoID = old.id
            return todo
        }
    }
}
public struct JournalState: Equatable {
    public var draft: [Todo] = [Todo()]
    public var hours = 2.0
    public var sessions: [WorkLog] = []
    public var pendingReviewID: UUID?
    /// The pause interval created by `lockin://update`; the next launch resumes work only if it is still the current interval.
    public var resumeAfterUpdateID: UUID?
    /// What the last `lockin backfill` changed, so `lockin backfill --undo` can put it back.
    public var lastBackfill: BackfillRecord?
    public init() {}
    /// The session still running, if any. Only the last unfinished session counts.
    public var openSessionIndex: Int? { sessions.lastIndex { $0.endedAt == nil } }
    public var openSession: WorkLog? { openSessionIndex.map { sessions[$0] } }
    /// The plan's tasks without the planner's blank row.
    public var plannedTasks: [Todo] { draft.filter(\.hasTitle) }
    /// Replaces the plan. An empty plan keeps one blank row ready for typing in the planner.
    public mutating func setPlan(_ todos: [Todo]) { draft = todos.isEmpty ? [Todo()] : todos }
    /// A work target is more than zero and at most a day.
    public static func isValidTarget(hours: Double) -> Bool { hours.isFinite && hours > 0 && hours <= 24 }
}
