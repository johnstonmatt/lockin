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
        case .remote(let command): return report(try AppClient.send(command))
        case .updateTask(let number, let text):
            let id = try AppClient.snapshot().task(number: number).id
            return report(try AppClient.send(.updateTask(id: id, title: text.title, link: text.link)))
        case .setTaskCompleted(let number, let completed):
            let id = try AppClient.snapshot().task(number: number).id
            return report(try AppClient.send(.setTaskCompleted(id: id, completed: completed)))
        case .deleteTask(let number):
            return report(try AppClient.send(.deleteTask(id: try AppClient.snapshot().task(number: number).id)))
        case .backfill(let range):
            let (start, end) = try BackfillRange.resolve(range, now: Date())
            return report(try AppClient.send(.backfill(start: start, end: end)))
        }
        return 0
    } catch let error as UsageError {
        printError(error.message)
        return 2
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

/// Prints the app's reply: its message on stdout if done, on stderr if refused.
func report(_ reply: RemoteReply) -> Int32 {
    if reply.ok { print(reply.message) } else { printError(reply.message) }
    return reply.ok ? 0 : 1
}

/// Writes "lockin: <message>" to stderr.
func printError(_ message: String) {
    FileHandle.standardError.write(Data("lockin: \(message)\n".utf8))
}

exit(run(Array(CommandLine.arguments.dropFirst())))
