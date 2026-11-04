import Foundation
import LockInCore

/// `lockin break`: takes a break, or joins the one in progress, and counts it down until it ends.
/// Ctrl-C ends the break early and keeps the unused time, like getting back to work early in the app.
enum BreakCountdown {
    static func run() throws -> Int32 {
        if try AppClient.snapshot().session?.phase != .break {
            let reply = try AppClient.send(.takeBreak)
            guard reply.ok else { return report(reply) }
        }
        let interrupted = Flag()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { interrupted.isSet = true }
        interrupt.resume()
        let line = StatusLine()
        while true {
            let snapshot = try AppClient.snapshot()
            guard let log = snapshot.session, log.phase == .break else {
                // The app ended the break: it ran out, or work resumed, paused or ended some other way.
                line.finish(ending(snapshot)); return 0
            }
            guard snapshot.appRunning else {
                line.finish("Lock In quit, so the break isn't being counted. Run lockin open to reopen it."); return 1
            }
            let left = log.breakBalance(at: Date())
            if interrupted.isSet {
                let reply = try AppClient.send(.resume)
                line.finish(reply.ok ? "Back to work · \(WorkStats.clock(left)) of break kept." : "lockin: \(reply.message)")
                return reply.ok ? 0 : 1
            }
            line.show("On break · \(WorkStats.clock(left)) left · Ctrl-C to get back to work")
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
    }

    private static func ending(_ snapshot: Snapshot) -> String {
        guard let log = snapshot.session else { return "The session has ended." }
        if log.phase == .pause { return "Paused" + (log.intervals.last?.reason.map { ": \($0)" } ?? ".") }
        return "Break over · back to work."
    }
}

private final class Flag: @unchecked Sendable { var isSet = false }

/// One line that redraws in place on a terminal. When output is piped, only the first and final lines are written.
private final class StatusLine {
    private let terminal = isatty(STDOUT_FILENO) != 0
    private var shown = false
    func show(_ text: String) {
        if terminal { write("\r\u{1B}[2K" + text) } else if !shown { write(text + "\n") }
        shown = true
    }
    func finish(_ text: String) { write((terminal && shown ? "\r\u{1B}[2K" : "") + text + "\n") }
    private func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
}
