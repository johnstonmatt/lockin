import Foundation
import LockInCore

/// Exit status: 0 done, 1 refused or failed, 2 usage error.
func run(_ arguments: [String]) -> Int32 {
    do {
        let invocation = try parse(arguments)
        switch invocation {
        case .open: try AppClient.open(background: false)
        case .help: print(usage)
        case .status(let json):
            let snapshot = try AppClient.snapshot()
            print(json ? snapshot.statusJSON : snapshot.statusText)
        case .tasks: print(try AppClient.snapshot().tasksText)
        case .history(let count): print(try AppClient.snapshot().historyText(count: count))
        case .takeBreak: return try BreakCountdown.run()
        case .upgrade: return try Upgrade.run()
        default: return try send(invocation)
        }
        return 0
    } catch let error as UsageError {
        FileHandle.standardError.write(Data("lockin: \(error.message)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("lockin: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

/// Commands the app carries out. Task numbers are resolved against the journal here, so the app gets stable IDs.
private func send(_ invocation: Invocation) throws -> Int32 {
    let command: RemoteCommand
    switch invocation {
    case .start(let hours): command = .start(hours: hours)
    case .pause(let reason): command = .pause(reason: reason)
    case .resume: command = .resume
    case .finish: command = .finish
    case .end(let reason): command = .end(reason: reason)
    case .addTask(let text): command = .addTask(title: text.newTitle, link: text.link ?? "")
    case .updateTask(let number, let text):
        command = .updateTask(id: try AppClient.snapshot().task(number: number).id, title: text.title, link: text.link)
    case .setTaskCompleted(let number, let completed):
        command = .setTaskCompleted(id: try AppClient.snapshot().task(number: number).id, completed: completed)
    case .deleteTask(let number): command = .deleteTask(id: try AppClient.snapshot().task(number: number).id)
    case .backfill(let range):
        let (start, end) = try BackfillRange.resolve(range, now: Date())
        command = .backfill(start: start, end: end)
    case .undoBackfill: command = .undoBackfill
    case .open, .help, .status, .tasks, .history, .takeBreak, .upgrade: return 0
    }
    return report(try AppClient.send(command))
}

/// Prints the app's reply: its message on stdout if done, on stderr if refused.
func report(_ reply: RemoteReply) -> Int32 {
    if reply.ok { print(reply.message) } else { FileHandle.standardError.write(Data("lockin: \(reply.message)\n".utf8)) }
    return reply.ok ? 0 : 1
}

exit(run(Array(CommandLine.arguments.dropFirst())))
