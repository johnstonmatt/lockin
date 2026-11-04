import Foundation
import LockInCore

/// A parsed command line. Task numbers are 1-based positions in `lockin tasks`, resolved to IDs before sending.
enum Invocation: Equatable {
    case open
    case help
    case status(json: Bool)
    case tasks
    case history(count: Int)
    case start(hours: Double?)
    case pause(reason: String)
    case takeBreak
    case resume
    case finish
    case end(reason: String)
    case addTask(TaskText)
    case updateTask(number: Int, TaskText)
    case setTaskCompleted(number: Int, completed: Bool)
    case deleteTask(number: Int)
    case upgrade
    case backfill(range: String)
    case undoBackfill
}

/// A task as typed: "title", "link", or "title - link". At least one part is set.
struct TaskText: Equatable {
    var title: String?
    var link: String?
    /// The title for a new task, read from the link when only a link was given.
    var newTitle: String { title ?? link.map(Todo.title(fromLink:)) ?? "" }
}

struct UsageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

let usage = """
    Usage: lockin [command]

    With no command, shows the status.
    Quote text that contains spaces: lockin pause "lunch with Sam"

    Session
      status [--json]          Phase, time left, break balance and tasks
      open                     Open the Lock In window
      start [--hours H]        Start a session from the plan, optionally setting its work target
      pause <reason>           Pause work, recording why
      break                    Take earned break time and count it down; Ctrl-C ends it early
      resume                   Get back to work after a break or pause
      finish                   End a session that has reached its target
      end <reason>             End a session early, e.g. "Starting a new day"

    Tasks (the running session's, or the next session's plan)
      tasks                    List tasks with their numbers
      task add <task>          <task> is "<title>", "<link>", or "<title> - <link>"
      task <n> <task>          Change task n's title, link, or both
      task done <n>            Check off a task during a session
      task undo <n>            Mark a task not done
      task rm <n>              Remove a task

    History
      history [-n N]           The last N sessions (default 7)
      backfill <range>         Record time you worked without Lock In counting it, such as
                               9:00-10:30, 22:30-01:15 (past midnight), 23:00-now, or
                               2026-11-03T22:30-2026-11-04T01:15. Times without a date
                               mean their most recent occurrence.
      backfill --undo          Remove the last backfill

    upgrade                    Install the latest release from GitHub

    Commands that change a session are carried out by the Lock In app, which is
    launched in the background if it isn't running.
    """

func parse(_ arguments: [String]) throws -> Invocation {
    var args = arguments
    guard !args.isEmpty else { return .status(json: false) }
    let command = args.removeFirst()
    switch command {
    case "open": try noMore(args, command); return .open
    case "help", "-h", "--help": return .help
    case "status":
        let json = take(flag: "--json", from: &args)
        try noMore(args, command); return .status(json: json)
    case "tasks": try noMore(args, command); return .tasks
    case "history", "log":
        let count = try take(option: ["-n", "--count"], from: &args).map { value -> Int in
            guard let n = Int(value), n > 0 else { throw UsageError("-n needs a positive whole number.") }
            return n
        } ?? 7
        try noMore(args, command); return .history(count: count)
    case "start":
        let hours = try take(option: ["--hours"], from: &args).map { value -> Double in
            guard let hours = Double(value), hours.isFinite, hours > 0, hours <= 24 else {
                throw UsageError("--hours needs a number between 0 and 24.")
            }
            return hours
        }
        try noMore(args, command); return .start(hours: hours)
    case "pause": return .pause(reason: try single(args, "pause", missing: "Say why you're pausing: lockin pause <reason>"))
    case "break": try noMore(args, command); return .takeBreak
    case "resume": try noMore(args, command); return .resume
    case "finish": try noMore(args, command); return .finish
    case "end": return .end(reason: try single(args, "end", missing: "Say why you're ending early: lockin end <reason>"))
    case "task": return try parseTask(args)
    case "upgrade": try noMore(args, command); return .upgrade
    case "backfill":
        if take(flag: "--undo", from: &args) { try noMore(args, command); return .undoBackfill }
        return .backfill(range: try single(args, "backfill", missing: "Give the time range you worked: lockin backfill 9:00-10:30"))
    default: throw UsageError("Unknown command “\(command)”. Run lockin help.")
    }
}

private func parseTask(_ arguments: [String]) throws -> Invocation {
    var args = arguments
    guard !args.isEmpty else { throw UsageError("Usage: lockin task add|<n>|done|undo|rm …") }
    let action = args.removeFirst()
    if let n = Int(action) {
        guard n > 0 else { throw UsageError("Task numbers start at 1. Run lockin tasks to see them.") }
        let text = try single(args, "task \(n)", missing: "Give the new title or link: lockin task \(n) \"<title> - <link>\"")
        return .updateTask(number: n, try parseTaskText(text))
    }
    switch action {
    case "add":
        let text = try single(args, "task add", missing: "Give the task a title or link: lockin task add \"<title> - <link>\"")
        return .addTask(try parseTaskText(text))
    case "done": return .setTaskCompleted(number: try number(args, action), completed: true)
    case "undo", "undone": return .setTaskCompleted(number: try number(args, action), completed: false)
    case "rm", "remove", "delete": return .deleteTask(number: try number(args, action))
    default: throw UsageError("Unknown task action “\(action)”. Use add, a task number, done, undo or rm.")
    }
}

/// Free text such as a reason or task: exactly one argument, so text with spaces must be quoted.
private func single(_ args: [String], _ command: String, missing: String) throws -> String {
    if args.count > 1 { throw UsageError("Quote text with spaces: lockin \(command) \"\(args.joined(separator: " "))\"") }
    guard let text = args.first, !text.isBlank else { throw UsageError(missing) }
    return text.trimmed
}

/// "title", "link", or "title - link". Titles may contain " - "; only the last one can come before a link.
func parseTaskText(_ text: String) throws -> TaskText {
    func isLink(_ part: String) -> Bool { !part.isBlank && Todo.isValidLink(part) }
    // A mistyped link is an error rather than quietly becoming part of the title.
    func looksLikeLink(_ part: String) -> Bool { ["http://", "https://"].contains { part.lowercased().hasPrefix($0) } }
    let text = text.trimmed
    if isLink(text) { return TaskText(link: text) }
    if let separator = text.range(of: " - ", options: .backwards) {
        let title = String(text[..<separator.lowerBound]).trimmed, link = String(text[separator.upperBound...]).trimmed
        if isLink(link) { return TaskText(title: title.isEmpty ? nil : title, link: link) }
        if looksLikeLink(link) { throw UsageError(Todo.linkRequirement) }
    }
    if looksLikeLink(text) { throw UsageError(Todo.linkRequirement) }
    return TaskText(title: text)
}

private func number(_ args: [String], _ action: String) throws -> Int {
    guard args.count == 1, let n = Int(args[0]), n > 0 else {
        throw UsageError("Give the task's number from lockin tasks: lockin task \(action) <n>")
    }
    return n
}

private func take(flag: String, from args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: flag) else { return false }
    args.remove(at: index); return true
}

private func take(option names: [String], from args: inout [String]) throws -> String? {
    guard let index = args.firstIndex(where: names.contains) else { return nil }
    guard index + 1 < args.count else { throw UsageError("\(args[index]) needs a value.") }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}

private func noMore(_ args: [String], _ command: String) throws {
    guard args.isEmpty else { throw UsageError("Unexpected “\(args.joined(separator: " "))” after \(command).") }
}
