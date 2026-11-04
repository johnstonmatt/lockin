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
            MainActor.assumeIsolated {
                guard let store = self?.store else { return }
                // Delivered immediately: NSApplication otherwise holds distributed notifications while the app is inactive.
                DistributedNotificationCenter.default().postNotificationName(
                    channel.reply, object: requestID, userInfo: RemoteChannel.encode(store.perform(command)), deliverImmediately: true)
            }
        }
    }
}

extension Store {
    /// Runs a CLI command through the same methods as the UI, so the same rules apply (Hardcore Mode, pause reasons,
    /// earned breaks). The reply carries the app's own explanation when a command is refused.
    func perform(_ command: RemoteCommand) -> RemoteReply {
        message = nil
        now = Date()
        func refused(_ fallback: String) -> RemoteReply { .failure(message ?? fallback) }
        let noSession = RemoteReply.failure("No session is running.")
        // Saving the review replaces the plan, so changing it now would be lost.
        let reviewFirst = RemoteReply.failure("Review your last session in Lock In before planning the next one.")
        switch command {
        case .ping:
            return .success("Lock In is running.")

        case .start(let hours):
            if active { return .failure("A session is already running.") }
            if journal.pendingReviewID != nil {
                showReview = true; NSApp?.showMainWindow()
                return .failure("Review your last session in Lock In before starting a new one.")
            }
            if let hours {
                guard JournalState.isValidTarget(hours: hours) else { return .failure("Use a work target between 0 and 24 hours.") }
                commitJournal { $0.hours = hours }
            }
            if journal.plannedTasks.isEmpty {
                return .failure("Add at least one task before starting: lockin task add \"…\"")
            }
            start()
            guard active else { return refused("Lock In couldn't start the session.") }
            return .success("Started a \(WorkStats.format(journal.hours * 3600)) session.")

        case .pause(let reason):
            guard let log = workLog else { return noSession }
            if log.phase == .pause { return .failure("Already paused.") }
            if reason.isBlank { return .failure("Pausing needs a reason.") }
            pause(reason: reason)
            return workLog?.phase == .pause ? .success("Paused: \(reason.trimmed)") : refused("Lock In couldn't pause.")

        case .takeBreak:
            guard let log = workLog else { return noSession }
            if log.phase == .break { return .failure("Already on a break.") }
            if log.phase == .pause { return .failure("Resume before taking a break.") }
            takeBreak()
            guard let log = workLog, log.phase == .break else { return refused("Lock In couldn't start a break.") }
            return .success("On break for \(WorkStats.clock(log.breakBalance(at: Date()))).")

        case .resume:
            guard let log = workLog else { return noSession }
            if log.phase?.isFocused == true { return .failure("Already working.") }
            resume()
            return workLog?.phase?.isFocused == true ? .success("Back to work.") : refused("Lock In couldn't resume.")

        case .finish:
            guard let log = workLog else { return noSession }
            guard log.targetReached(at: now) else {
                return .failure("\(WorkStats.clock(log.remaining(at: now))) of work left. To stop early: lockin end <reason>")
            }
            finishSession()
            return workLog == nil ? .success("Session finished. Review it in Lock In.") : refused("Lock In couldn't finish the session.")

        case .end(let reason):
            guard workLog != nil else { return noSession }
            if locked { return .failure("Hardcore Mode is active. The session can end once its target is reached.") }
            if reason.isBlank { return .failure("Ending a session early needs a reason.") }
            endSession(reason: reason)
            return workLog == nil ? .success("Session ended. Review it in Lock In.") : refused("Lock In couldn't end the session.")

        case .addTask(let title, let link):
            let todo = Todo().with(title: title, link: link)
            guard todo.hasTitle else { return .failure("A task needs a title.") }
            guard todo.validLink else { return .failure(Todo.linkRequirement) }
            if workLog != nil {
                return addTask(title: title, link: link) ? .success("Added “\(todo.title)” to this session.") : refused("Lock In couldn't add the task.")
            }
            if journal.pendingReviewID != nil { return reviewFirst }
            guard commitJournal({ $0.draft = $0.plannedTasks + [todo] }) else { return refused("Lock In couldn't save the task.") }
            return .success("Added “\(todo.title)” to the next session's plan.")

        case .updateTask(let id, let title, let link):
            let inSession = workLog != nil
            if !inSession, journal.pendingReviewID != nil { return reviewFirst }
            guard let todo = (workLog?.todos ?? journal.draft).first(where: { $0.id == id }) else {
                return .failure(inSession ? "No such task in this session." : "No such task in the plan.")
            }
            let updated = todo.with(title: title ?? todo.title, link: link ?? todo.link)
            guard updated.hasTitle else { return .failure("A task needs a title.") }
            guard updated.validLink else { return .failure(Todo.linkRequirement) }
            if inSession {
                return updateTask(id: id, title: updated.title, link: updated.link) ? .success("Updated “\(updated.title)”.") : refused("Lock In couldn't update the task.")
            }
            guard commitJournal({ journal in
                if let index = journal.draft.firstIndex(where: { $0.id == id }) { journal.draft[index] = updated }
            }) else { return refused("Lock In couldn't save the plan.") }
            return .success("Updated “\(updated.title)”.")

        case .backfill(let start, let end):
            let phase = workLog?.phase
            var backfilled: BackfillResult?
            do {
                let saved = try commitJournal { journal in
                    if let index = journal.openSessionIndex { journal.sessions[index].advance(at: now) }
                    backfilled = try journal.backfill(from: start, to: end, now: now)
                }
                guard saved else { return refused("Lock In couldn't save the backfill.") }
            }
            catch let error as BackfillError { return .failure(Self.explain(error)) }
            catch { return .failure(error.localizedDescription) }
            guard let result = backfilled else { return refused("Lock In couldn't save the backfill.") }
            // Earlier work can mean the target has now been reached.
            if phase == .work, workLog?.phase == .overtime { runHook(.overtime) }
            var message = "Backfilled \(WorkStats.format(result.addedSeconds)): \(Self.moment(start)) → \(Self.moment(min(end, now)))"
            if result.createdSession { message += ", as a new session." }
            else if result.movedStart { message += ". The session now starts \(Self.moment(result.sessionStartedAt))." }
            else { message += ", in the session that started \(Self.moment(result.sessionStartedAt))." }
            if result.alreadyRecordedSeconds >= 60 { message += " \(WorkStats.format(result.alreadyRecordedSeconds)) of it was already recorded." }
            return .success(message + " Undo with: lockin backfill --undo")

        case .undoBackfill:
            guard journal.lastBackfill != nil else { return .failure("There's no backfill to undo.") }
            var undone = false
            guard commitJournal({ undone = $0.undoBackfill(now: now) }) else { return refused("Lock In couldn't save the undo.") }
            guard undone else { return .failure("There's no backfill to undo.") }
            return .success("Removed the last backfill.")

        case .addEvent(let text):
            guard workLog != nil else { return .failure("No session is running. Events are recorded on the running session.") }
            if text.isBlank { return .failure("An event needs some text.") }
            return addEvent(text) ? .success("Recorded “\(text.trimmed)”.") : refused("Lock In couldn't record the event.")

        case .setTaskCompleted(let id, let completed):
            guard workLog != nil else { return .failure("Tasks can be checked off during a session.") }
            return setTaskCompleted(id: id, completed) ? .success(completed ? "Done." : "Marked not done.") : refused("No such task in this session.")

        case .deleteTask(let id):
            if workLog != nil {
                return deleteTask(id: id) ? .success("Removed.") : refused("No such task in this session.")
            }
            guard journal.draft.contains(where: { $0.id == id }) else { return .failure("No such task in the plan.") }
            guard commitJournal({ $0.setPlan($0.draft.filter { $0.id != id }) }) else { return refused("Lock In couldn't save the plan.") }
            return .success("Removed.")
        }
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
