import Foundation

/// The files in ~/.lockin, as defined by the JSON Schemas in `Schemas/`. These types are the on-disk contract:
/// they're kept separate from the in-memory models so a model can change without silently changing the files.
/// Keys are spelled out, not derived, so the files read the same whatever the models are called.
public enum FileFormat {
    public static let schemaBase = "https://raw.githubusercontent.com/johnstonmatt/lockin/main/Schemas/"
    /// Files with a newer version than these were written by a newer Lock In: they're read-only to this build.
    public static let sessionVersion = 1
    public static let settingsVersion = 1

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(date))
        }
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = Timestamp.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(text)” isn't an ISO 8601 date-time.")
            }
            return date
        }
        return decoder
    }()

    public enum Problem: LocalizedError, Equatable {
        case newerVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .newerVersion(let version): return "It was written by a newer version of Lock In (schema version \(version))."
            }
        }
    }

    /// Decodes a file after checking its schema version, so a newer file is reported rather than half-read.
    private struct Header: Decodable {
        var version: Int
        enum CodingKeys: String, CodingKey { case version = "schema_version" }
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, supported: Int) throws -> T {
        let version = try decoder.decode(Header.self, from: data).version
        guard version <= supported else { throw Problem.newerVersion(version) }
        return try decoder.decode(type, from: data)
    }
}

/// ISO 8601 in UTC with microseconds, e.g. "2026-11-03T09:00:00.123456Z". Microseconds keep interval boundaries
/// in order; whole seconds alone would not. Reading also accepts other fractions and offsets, for hand-edited files.
public enum Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func string(_ date: Date) -> String {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        let seconds = (micros / 1_000_000).rounded(.down)
        let fraction = Int(micros - seconds * 1_000_000)
        let whole = formatter.string(from: Date(timeIntervalSince1970: seconds))
        return whole.dropLast() + String(format: ".%06dZ", fraction)
    }

    public static func date(_ text: String) -> Date? {
        guard let match = text.wholeMatch(of: #/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})/#),
              let whole = formatter.date(from: String(match.1) + String(match.3)) else { return nil }
        let fraction = match.2.flatMap { Double("0" + $0) } ?? 0
        return Date(timeIntervalSince1970: whole.timeIntervalSince1970 + fraction)
    }
}

// MARK: - Session files: ~/.lockin/sessions/<id>.json

/// One session, as described by `Schemas/session-v1.schema.json`.
public struct SessionFile: Codable, Equatable {
    public static let schemaURL = FileFormat.schemaBase + "session-v1.schema.json"
    public var schema: String? = SessionFile.schemaURL
    public var schemaVersion = FileFormat.sessionVersion
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    /// While the session is open: the last time the app confirmed it was running. A crash or force quit turns
    /// the time after this into a pause, since nothing was counting.
    public var checkpointAt: Date?
    public var targetSeconds: Double
    public var finishedNaturally: Bool
    public var endReason: String?
    public var reviewed: Bool
    public var tasks: [TaskRecord]
    public var intervals: [IntervalRecord]
    public var events: [EventRecord]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema", schemaVersion = "schema_version", id, startedAt = "started_at", endedAt = "ended_at"
        case checkpointAt = "checkpoint_at", targetSeconds = "target_seconds", finishedNaturally = "finished_naturally"
        case endReason = "end_reason", reviewed, tasks, intervals, events
    }

    public init(_ log: WorkLog, checkpoint: Date?) {
        id = log.id; startedAt = log.startedAt; endedAt = log.endedAt
        checkpointAt = log.endedAt == nil ? checkpoint : nil
        targetSeconds = log.targetSeconds; finishedNaturally = log.finishedNaturally
        endReason = log.endReason; reviewed = log.reviewed
        tasks = log.todos.map(TaskRecord.init); intervals = log.intervals.map(IntervalRecord.init)
        events = log.events.map(EventRecord.init)
    }

    public var log: WorkLog {
        var log = WorkLog(todos: tasks.map(\.todo), targetSeconds: targetSeconds, now: startedAt)
        log.id = id; log.endedAt = endedAt; log.finishedNaturally = finishedNaturally
        log.endReason = endReason; log.reviewed = reviewed
        log.intervals = intervals.map(\.interval)
        log.events = events.map(\.event)
        return log
    }
}

public struct TaskRecord: Codable, Equatable {
    public var id: UUID
    public var title: String
    public var link: String?
    public var completed: Bool
    public var rollIntoNextSession: Bool
    /// The task this one was carried forward from.
    public var sourceTaskId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, title, link, completed, rollIntoNextSession = "roll_into_next_session", sourceTaskId = "source_task_id"
    }

    init(_ todo: Todo) {
        id = todo.id; title = todo.title; link = todo.link.isEmpty ? nil : todo.link
        completed = todo.completed; rollIntoNextSession = todo.rollForward; sourceTaskId = todo.sourceTodoID
    }

    var todo: Todo {
        var todo = Todo(title: title)
        todo.id = id; todo.link = link ?? ""; todo.completed = completed
        todo.rollForward = rollIntoNextSession; todo.sourceTodoID = sourceTaskId
        return todo
    }
}

public struct IntervalRecord: Codable, Equatable {
    public var id: UUID
    public var kind: WorkPhase
    public var startedAt: Date
    /// Absent on the interval still running.
    public var endedAt: Date?
    public var reason: String?
    /// Work added afterwards with `lockin backfill`. Left out, rather than false, on timed intervals.
    public var backfilled: Bool?

    enum CodingKeys: String, CodingKey {
        case id, kind, startedAt = "started_at", endedAt = "ended_at", reason, backfilled
    }

    init(_ interval: WorkInterval) {
        id = interval.id; kind = interval.kind; startedAt = interval.start; endedAt = interval.end
        reason = interval.reason; backfilled = interval.backfilled ? true : nil
    }

    var interval: WorkInterval {
        WorkInterval(id: id, kind: kind, start: startedAt, end: endedAt, reason: reason, backfilled: backfilled ?? false)
    }
}

public struct EventRecord: Codable, Equatable {
    public var id: UUID
    public var at: Date
    public var text: String

    init(_ event: SessionEvent) { id = event.id; at = event.at; text = event.text }

    var event: SessionEvent {
        var event = SessionEvent(at: at, text: text)
        event.id = id
        return event
    }
}

// MARK: - Settings: ~/.lockin/settings.json

/// Everything that isn't a session, as described by `Schemas/settings-v1.schema.json`:
/// profiles, the plan for the next session, and the app's bookkeeping between launches.
public struct SettingsFile: Codable, Equatable {
    public static let schemaURL = FileFormat.schemaBase + "settings-v1.schema.json"
    public var schema: String? = SettingsFile.schemaURL
    public var schemaVersion = FileFormat.settingsVersion
    public var profiles: [ProfileRecord]
    public var selectedProfileId: UUID?
    /// What the running session enforces: a copy of its profile, taken when it started.
    public var activeSession: ActiveSessionRecord?
    public var plan: PlanRecord
    /// The finished session waiting for review.
    public var pendingReviewSessionId: UUID?
    /// The pause interval an update created; the next launch resumes work if it's still the current interval.
    public var resumeAfterUpdateIntervalId: UUID?
    /// What the last `lockin backfill` changed, so `lockin backfill --undo` can put it back.
    public var lastBackfill: LastBackfillRecord?

    enum CodingKeys: String, CodingKey {
        case schema = "$schema", schemaVersion = "schema_version", profiles, selectedProfileId = "selected_profile_id"
        case activeSession = "active_session", plan, pendingReviewSessionId = "pending_review_session_id"
        case resumeAfterUpdateIntervalId = "resume_after_update_interval_id", lastBackfill = "last_backfill"
    }

    public init(preferences: SavedState, journal: JournalState) {
        profiles = preferences.profiles.map(ProfileRecord.init)
        selectedProfileId = preferences.selectedProfileID
        activeSession = preferences.session.map { ActiveSessionRecord(profile: ProfileRecord($0.profile), hardcore: $0.locked) }
        plan = PlanRecord(targetHours: journal.hours, tasks: journal.draft.map(TaskRecord.init))
        pendingReviewSessionId = journal.pendingReviewID
        resumeAfterUpdateIntervalId = journal.resumeAfterUpdateID
        lastBackfill = journal.lastBackfill.map(LastBackfillRecord.init)
    }

    public var preferences: SavedState {
        var state = SavedState()
        state.profiles = profiles.map(\.profile)
        state.selectedProfileID = selectedProfileId
        state.session = activeSession.map { FocusSession(profile: $0.profile.profile, locked: $0.hardcore) }
        return state
    }

    /// The journal without its sessions, which live in their own files.
    public var journal: JournalState {
        var journal = JournalState()
        journal.hours = plan.targetHours
        journal.draft = plan.tasks.map(\.todo)
        journal.pendingReviewID = pendingReviewSessionId
        journal.resumeAfterUpdateID = resumeAfterUpdateIntervalId
        journal.lastBackfill = lastBackfill?.record
        return journal
    }
}

public struct ProfileRecord: Codable, Equatable {
    public enum Mode: String, Codable { case block, allow }
    public struct App: Codable, Equatable {
        public var name: String
        public var bundleId: String
        enum CodingKeys: String, CodingKey { case name, bundleId = "bundle_id" }
    }
    public var id: UUID
    public var name: String
    public var symbol: String
    public var websites: [String]
    public var applications: [App]
    public var blockingMode: Mode
    /// Shell scripts by event: start, stop, overtime, break, resume, pause.
    public var hooks: [String: String]
    public var passwordSalt: String?
    public var passwordHash: String?

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, websites, applications, blockingMode = "blocking_mode", hooks
        case passwordSalt = "password_salt", passwordHash = "password_hash"
    }

    init(_ profile: Profile) {
        id = profile.id; name = profile.name; symbol = profile.symbol; websites = profile.websites
        applications = profile.applications.map { App(name: $0.name, bundleId: $0.bundleID) }
        blockingMode = profile.blockingMode == .block ? .block : .allow
        hooks = profile.hooks; passwordSalt = profile.passwordSalt; passwordHash = profile.passwordHash
    }

    var profile: Profile {
        var profile = Profile(name: name, symbol: symbol)
        profile.id = id; profile.websites = websites
        profile.applications = applications.map { BlockedApp(name: $0.name, bundleID: $0.bundleId) }
        profile.blockingMode = blockingMode == .block ? .block : .allow
        profile.hooks = hooks; profile.passwordSalt = passwordSalt; profile.passwordHash = passwordHash
        return profile
    }
}

public struct ActiveSessionRecord: Codable, Equatable {
    public var profile: ProfileRecord
    /// Hardcore Mode: the session can't be ended or quit until its target is reached.
    public var hardcore: Bool
}

public struct PlanRecord: Codable, Equatable {
    public var targetHours: Double
    /// Includes the planner's blank row, if it has one.
    public var tasks: [TaskRecord]
    enum CodingKeys: String, CodingKey { case targetHours = "target_hours", tasks }
}

public struct LastBackfillRecord: Codable, Equatable {
    public var sessionId: UUID
    /// The backfill created the session, so undoing it removes the session.
    public var createdSession: Bool
    public var previousStartedAt: Date
    public var previousIntervals: [IntervalRecord]
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", createdSession = "created_session", previousStartedAt = "previous_started_at"
        case previousIntervals = "previous_intervals", at
    }

    init(_ record: BackfillRecord) {
        sessionId = record.sessionID; createdSession = record.createdSession
        previousStartedAt = record.previousStartedAt; previousIntervals = record.previousIntervals.map(IntervalRecord.init)
        at = record.at
    }

    var record: BackfillRecord {
        BackfillRecord(sessionID: sessionId, createdSession: createdSession, previousStartedAt: previousStartedAt,
                       previousIntervals: previousIntervals.map(\.interval), at: at)
    }
}
