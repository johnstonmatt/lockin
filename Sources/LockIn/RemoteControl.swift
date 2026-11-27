import AppKit
import LockInCore

/// Answers `lockin` CLI requests. Distributed notifications reach only local processes running as this user, unlike
/// `lockin://` URLs, which web pages can open. So the CLI can pause with a reason or edit tasks, and the URLs can't.
@MainActor final class RemoteControl {
    private weak var store: Store?
    private var observer: NSObjectProtocol?
    init(store: Store, channel: RemoteChannel) {
        self.store = store
        observer = DistributedNotificationCenter.default().addObserver(forName: channel.request, object: nil, queue: .main) { [weak self] note in
            guard let requestID = note.object as? String,
                  let command = RemoteChannel.decode(RemoteCommand.self, from: note.userInfo) else { return }
            Task { @MainActor in
                guard let store = self?.store else { return }
                // Delivered immediately: NSApplication otherwise holds distributed notifications while the app is inactive.
                DistributedNotificationCenter.default().postNotificationName(
                    channel.reply, object: requestID, userInfo: RemoteChannel.encode(await store.perform(command)), deliverImmediately: true)
            }
        }
    }
}

extension Store {
    /// Runs a CLI command through the same methods as the UI, so the same rules apply (Hardcore Mode, pause reasons,
    /// earned breaks). The reply carries the app's own explanation when a command is refused.
    func perform(_ command: RemoteCommand, using importer: WorkImporter? = nil) async -> RemoteReply {
        message = nil
        now = clock()
        do { return .success(try await run(command, using: importer)) }
        catch { return .failure(error.localizedDescription) }
    }

    private func run(_ command: RemoteCommand, using importer: WorkImporter?) async throws -> String {
        /// A refusal the app explained in `message`, or `fallback` if it didn't.
        func refused(_ fallback: String) -> LockInError { LockInError(message ?? fallback) }
        let noSession = LockInError("No session is running.")
        switch command {
        case .ping:
            return "Lock In is running."

        case .start(let hours):
            if active { throw LockInError("A session is already running.") }
            if journal.pendingReviewID != nil {
                presentReview()
                throw LockInError("Review your last session in Lock In before starting a new one.")
            }
            if let hours {
                guard JournalState.isValidTarget(hours: hours) else { throw LockInError("Use a work target between 0 and 24 hours.") }
                try commitJournal { $0.hours = hours }
            }
            start()
            guard active else { throw refused("Lock In couldn't start the session.") }
            return "Started a \(WorkStats.format(journal.hours * 3600)) session."

        case .pause(let reason):
            guard let log = workLog else { throw noSession }
            if log.phase == .pause { throw LockInError("Already paused.") }
            if reason.isBlank { throw LockInError("Pausing needs a reason.") }
            pause(reason: reason)
            guard workLog?.phase == .pause else { throw refused("Lock In couldn't pause.") }
            return "Paused: \(reason.trimmed)"

        case .takeBreak:
            guard let log = workLog else { throw noSession }
            if log.phase == .break { throw LockInError("Already on a break.") }
            if log.phase == .pause { throw LockInError("Resume before taking a break.") }
            takeBreak()
            guard let log = workLog, log.phase == .break else { throw refused("Lock In couldn't start a break.") }
            return "On break for \(WorkStats.clock(log.breakBalance(at: clock())))."

        case .resume:
            guard let log = workLog else { throw noSession }
            if log.phase?.isFocused == true { throw LockInError("Already working.") }
            resume()
            guard workLog?.phase?.isFocused == true else { throw refused("Lock In couldn't resume.") }
            return "Back to work."

        case .finish:
            guard let log = workLog else { throw noSession }
            guard log.targetReached(at: now) else {
                throw LockInError("\(WorkStats.clock(log.remaining(at: now))) of work left. To stop early: lockin end <reason>")
            }
            finishSession()
            guard workLog == nil else { throw refused("Lock In couldn't finish the session.") }
            return "Session finished. Review it in Lock In."

        case .end(let reason):
            guard workLog != nil else { throw noSession }
            if locked { throw LockInError("Hardcore Mode is active. The session can end once its target is reached.") }
            if reason.isBlank { throw LockInError("Ending a session early needs a reason.") }
            endSession(reason: reason)
            guard workLog == nil else { throw refused("Lock In couldn't end the session.") }
            return "Session ended. Review it in Lock In."

        case .addTask(let input):
            return try await addWork(input, using: importer).value

        case .updateTask(let id, let title, let link):
            let task = graphSessionTasks.first { $0.id == id }
            let title = title ?? task?.title ?? "", link = link ?? task?.link ?? ""
            try renameWork(workID(ofTask: id), title: title, link: link)
            return "Updated “\(title.trimmed)”."

        case .setTaskCompleted(let id, let completed):
            try setWorkDone(workID(ofTask: id), done: completed)
            return completed ? "Done." : "Marked not done."

        case .deleteTask(let id):
            try removeWork(workID(ofTask: id))
            return "Removed."

        case .backfill(let start, let end):
            let phase = workLog?.phase
            var backfilled: BackfillResult?
            do {
                try commitJournal { journal in
                    if let index = journal.openSessionIndex { journal.sessions[index].advance(at: now) }
                    backfilled = try journal.backfill(from: start, to: end, now: now)
                }
            } catch let error as BackfillError { throw LockInError(Self.explain(error)) }
            guard let result = backfilled else { throw LockInError("Lock In couldn't save the backfill.") }
            // Earlier work can mean the target has now been reached.
            if phase == .work, workLog?.phase == .overtime { runHook(.overtime) }
            var message = "Backfilled \(WorkStats.format(result.addedSeconds)): \(Self.moment(start)) → \(Self.moment(min(end, now)))"
            if result.createdSession { message += ", as a new session." }
            else if result.movedStart { message += ". The session now starts \(Self.moment(result.sessionStartedAt))." }
            else { message += ", in the session that started \(Self.moment(result.sessionStartedAt))." }
            if result.alreadyRecordedSeconds >= 60 { message += " \(WorkStats.format(result.alreadyRecordedSeconds)) of it was already recorded." }
            return message + " Undo with: lockin backfill --undo"

        case .undoBackfill:
            var undone = false
            if journal.lastBackfill != nil { try commitJournal { undone = $0.undoBackfill(now: now) } }
            guard undone else { throw LockInError("There's no backfill to undo.") }
            return "Removed the last backfill."

        case .addEvent(let text):
            try addEvent(text)
            return "Recorded “\(text.trimmed)”."
        }
    }

    /// The work entry for a CLI task ID. A missing task gets the identity it would have had, which matches no work,
    /// so the work functions report it as missing in their usual order.
    private func workID(ofTask id: UUID) -> String {
        graphSessionTasks.first { $0.id == id }?.workIdentity ?? WorkNode.localID(id)
    }

    /// "Tue 3 Nov 22:30": backfill ranges can cross midnight, so the day is always shown.
    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func explain(_ error: BackfillError) -> String {
        switch error {
        case .empty: return "The range ends before it starts."
        case .inFuture: return "That range ends in the future."
        case .nothingToAdd: return "That time is already recorded as work or break."
        case .afterEnd(let end): return "The session ended \(moment(end)). Backfill up to then; time after it needs a separate range."
        case .spansSessions(let ends, let starts):
            return "That range covers the end of one session (\(moment(ends))) and the start of the next (\(moment(starts))). Backfill each part separately."
        }
    }
}
