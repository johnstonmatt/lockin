import Foundation
import LockInCore

/// What the CLI knows from disk: the app's journal snapshot, plus whether Hardcore Mode is on and the app is running.
struct Snapshot {
    var journal: JournalState
    var locked = false
    var appRunning = true
    /// When the figures are true as of: now, or the last checkpoint if the app isn't running to count time.
    var asOf: Date
    var calendar = Calendar.current

    var session: WorkLog? { journal.sessions.last { $0.endedAt == nil } }
    var reviewPending: Bool { journal.pendingReviewID != nil }
    /// The tasks `lockin tasks` numbers: the running session's, or the next session's plan.
    var tasks: [Todo] { session?.todos ?? journal.draft.filter(\.hasTitle) }

    func task(number: Int) throws -> Todo {
        guard tasks.indices.contains(number - 1) else {
            throw UsageError(tasks.isEmpty ? "There are no tasks." : "There's no task \(number). Run lockin tasks to see the numbers.")
        }
        return tasks[number - 1]
    }

    private func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
    private func day(_ date: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    // MARK: status

    var statusText: String {
        var lines: [String] = []
        if let log = session {
            let target = WorkStats.format(log.targetSeconds)
            let current = log.intervals.last
            switch log.phase {
            case .work?: lines.append("Working · \(WorkStats.clock(log.remaining(at: asOf))) left of \(target)")
            case .overtime?: lines.append("Overtime · +\(WorkStats.clock(log.seconds(.overtime, at: asOf))) past the \(target) target")
            case .break?: lines.append("On break · \(WorkStats.clock(log.breakBalance(at: asOf))) left")
            case .pause?:
                let since = current.map { " since \(time($0.start))" } ?? ""
                let reason = current?.reason.map { " · “\($0)”" } ?? ""
                lines.append("Paused\(since)\(reason)")
            case nil: break
            }
            var detail = ["Worked \(WorkStats.format(log.worked(at: asOf))) of \(target)"]
            if log.phase != .break { detail.append("break balance \(WorkStats.format(log.breakBalance(at: asOf)))") }
            if locked && !log.targetReached(at: asOf) { detail.append("Hardcore Mode") }
            lines.append(detail.joined(separator: " · "))
            if !appRunning {
                lines.append("Lock In isn't running, so time stopped counting at \(time(asOf)). Run lockin to reopen it.")
            }
            lines += ["", "Tasks"] + taskLines
        } else if reviewPending {
            lines.append("No session running. Your last session is waiting for review in Lock In.")
        } else {
            let count = tasks.count
            lines.append("No session running. Plan: \(WorkStats.format(journal.hours * 3600)) · \(count) task\(count == 1 ? "" : "s").")
            if count > 0 { lines += ["", "Plan"] + taskLines + ["", "Start with: lockin start"] }
            else { lines.append("Add a task with: lockin task add <title>") }
        }
        return lines.joined(separator: "\n")
    }

    var tasksText: String {
        if session == nil && reviewPending { return "Your last session is waiting for review in Lock In." }
        let heading = session == nil ? "Plan for the next session" : "This session"
        return ([heading] + taskLines).joined(separator: "\n")
    }

    private var taskLines: [String] {
        guard !tasks.isEmpty else { return ["  (none)"] }
        return tasks.enumerated().map { index, todo in
            let check = session == nil ? "" : (todo.completed ? "[x] " : "[ ] ")
            let link = todo.linkURL.map { " — \($0.absoluteString)" } ?? ""
            return "  \(index + 1). \(check)\(todo.title)\(link)"
        }
    }

    // MARK: history

    func historyText(count: Int) -> String {
        let recent = journal.sessions.suffix(count).reversed()
        guard !recent.isEmpty else { return "No sessions yet." }
        return recent.map { log in
            let now = log.endedAt ?? asOf
            let worked = "\(WorkStats.format(log.worked(at: now))) / \(WorkStats.format(log.targetSeconds))"
            let status: String
            if log.endedAt == nil { status = log.phase == .pause ? "paused" : "in progress" }
            else if log.finishedNaturally { status = "finished" }
            else { status = "ended early" + (log.endReason.map { ": \($0)" } ?? "") }
            let overtime = log.seconds(.overtime, at: now)
            let done = log.todos.filter(\.completed).count
            var parts = [day(log.startedAt).padding(toLength: 11, withPad: " ", startingAt: 0),
                         worked.padding(toLength: 16, withPad: " ", startingAt: 0),
                         "\(done)/\(log.todos.count) tasks".padding(toLength: 11, withPad: " ", startingAt: 0),
                         status]
            if overtime >= 60 { parts.append("(+\(WorkStats.format(overtime)) overtime)") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: JSON

    struct Status: Encodable {
        struct Task: Encodable { var title: String; var link: String?; var completed: Bool }
        var appRunning: Bool
        var reviewPending: Bool
        var phase: String?
        var phaseStartedAt: Date?
        var pauseReason: String?
        var locked: Bool
        var targetSeconds: Double?
        var remainingSeconds: Double?
        var workedSeconds: Double?
        var overtimeSeconds: Double?
        var breakBalanceSeconds: Double?
        /// The running session's tasks, or the next session's plan when none is running.
        var tasks: [Task]
    }

    var status: Status {
        let log = session
        let current = log?.intervals.last
        return Status(
            appRunning: appRunning, reviewPending: reviewPending,
            phase: log?.phase?.rawValue, phaseStartedAt: current?.start, pauseReason: current?.reason,
            locked: locked && log?.targetReached(at: asOf) == false,
            targetSeconds: log?.targetSeconds, remainingSeconds: log?.remaining(at: asOf),
            workedSeconds: log?.worked(at: asOf), overtimeSeconds: log?.seconds(.overtime, at: asOf),
            breakBalanceSeconds: log?.breakBalance(at: asOf),
            tasks: tasks.map { Status.Task(title: $0.title, link: $0.linkURL?.absoluteString, completed: $0.completed) })
    }

    var statusJSON: String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(status)) ?? Data(), as: UTF8.self)
    }
}
