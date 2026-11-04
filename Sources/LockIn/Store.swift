import AppKit
import SwiftUI
import CryptoKit
import LockInCore

@MainActor final class Store: ObservableObject {
    @Published var state = SavedState()
    @Published var now = Date()
    @Published var message: String?
    @Published var unlockedProfiles: Set<UUID> = []
    @Published var page: Page = .focus
    @Published var lockSession = false
    @Published var journal = JournalState()
    @Published var showPause = false
    @Published var showEndSession = false
    @Published var showReview = false
    @Published var showPlanner = false
    /// False when saved data couldn't be read: saving over it would lose it, so nothing is saved until it's fixed.
    private var writable = true
    private var lastCheckpoint = Date.distantPast
    private let directory: URL
    private let writer: StorageWriter
    /// Replaceable so tests can exercise update handling without quitting the test runner.
    var terminate: () -> Void = { NSApp?.terminate(nil) }
    private let enforceBlocking: Bool
    var workLog: WorkLog? { journal.openSession }
    var reviewIndex: Int? { journal.sessions.firstIndex { $0.id == journal.pendingReviewID } }
    let blocker = Blocker()
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// The pause the Mac's sleep started and the phase it interrupted, so waking can pick up where sleep left off.
    private var sleepPause: (id: UUID, phase: WorkPhase)?
    private var remoteControl: RemoteControl?
    enum Page: String, CaseIterable, Identifiable {
        case focus = "Focus", distractions = "Distractions", history = "History", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .focus: return "scope"
            case .distractions: return "hand.raised"
            case .history: return "chart.bar.xaxis"
            case .settings: return "slider.horizontal.3"
            }
        }
    }
    /// `directory` replaces ~/.lockin, e.g. in tests.
    /// `channel` is where `lockin` CLI commands arrive; tests pass nil, or a channel of their own, so they never
    /// answer the real CLI and the real app never answers them.
    init(directory: URL? = nil, runTimer: Bool = true, enforceBlocking: Bool = true, channel: RemoteChannel? = .app) {
        self.directory = directory ?? Storage.directory
        self.enforceBlocking = enforceBlocking
        var contents: Storage.Contents?
        do { contents = try Storage.load(from: self.directory) }
        catch { writable = false; message = "\(error.localizedDescription)\n\nLock In won't save anything until this is fixed, so the file is left as it is." }
        writer = StorageWriter(directory: self.directory, contents: contents ?? Storage.Contents())
        if let contents {
            state = contents.preferences; journal = contents.journal
            if !contents.skipped.isEmpty {
                message = "Some session files couldn't be read. They're left as they are and don't appear in History:\n" + contents.skipped.joined(separator: "\n")
            }
        }
        if state.profiles.isEmpty { state.profiles = [Profile()] }
        if !state.profiles.contains(where: { $0.id == state.selectedProfileID }) { state.selectedProfileID = state.profiles[0].id }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseForSleep() }
        }
        // didWake is a full wake (someone at the Mac), not the brief dark wakes for maintenance.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        }
        restoreSession(checkpoint: contents?.checkpoint)
        tick()
        if let channel { remoteControl = RemoteControl(store: self, channel: channel) }
        guard runTimer else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    var profile: Profile { state.profiles.first { $0.id == state.selectedProfileID } ?? state.profiles[0] }
    var active: Bool { state.session != nil }
    /// Hardcore Mode holds until the work target is reached; overtime can be ended, quit or updated freely.
    var locked: Bool { state.session?.locked == true && workLog?.targetReached(at: now) != true }
    /// Whether the open session has reached its target, so it can be finished (and is counting overtime).
    var targetReached: Bool { workLog?.targetReached(at: now) == true }
    var canEdit: Bool { !locked && (profile.passwordHash == nil || unlockedProfiles.contains(profile.id)) && !active }
    var timerText: String {
        guard let log = workLog else { return WorkStats.clock(journal.hours * 3600) }
        if log.phase == .break { return WorkStats.clock(log.breakBalance(at: now)) }
        // Past the target, the timer counts overtime up instead of work down.
        if log.targetReached(at: now) { return "+" + WorkStats.clock(log.seconds(.overtime, at: now)) }
        return WorkStats.clock(log.remaining(at: now))
    }
    func updateProfile(_ edit: (inout Profile) -> Void) {
        guard canEdit, let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        edit(&state.profiles[index]); persist()
    }
    func select(_ id: UUID) { guard !active else { return }; state.selectedProfileID = id; persist() }
    func addProfile() {
        guard !active else { return }
        let new = Profile(name: "New profile", symbol: "sparkles")
        state.profiles.append(new); state.selectedProfileID = new.id; persist()
    }
    func deleteProfile() {
        guard canEdit, state.profiles.count > 1 else { return }
        let id = profile.id
        state.profiles.removeAll { $0.id == id }
        state.selectedProfileID = state.profiles[0].id; persist()
    }
    func addWebsite(_ raw: String) {
        guard let rule = WebsiteRule.normalize(raw) else { message = "Enter a domain or website URL, such as reddit.com or youtube.com/shorts."; return }
        // Locked block lists can only become stricter. Allow lists cannot be expanded.
        if var session = state.session {
            guard session.profile.blockingMode == .block else { message = "Allow lists cannot be expanded during a session."; return }
            if !session.profile.websites.contains(rule) { session.profile.websites.append(rule) }
            state.session = session; persist(); return
        }
        updateProfile { if !$0.websites.contains(rule) { $0.websites.append(rule) } }
    }
    func start() {
        guard !active, writable else { return }
        now = Date()
        guard journal.pendingReviewID == nil else { showReview = true; return }
        let todos = journal.plannedTasks
        guard !todos.isEmpty else { showPlanner = true; message = "Add at least one task before starting."; return }
        guard todos.allSatisfy(\.validLink), JournalState.isValidTarget(hours: journal.hours) else {
            message = "Use a work target between 0 and 24 hours, and full web links (https://…) for tasks."; return
        }
        let log = WorkLog(todos: todos, targetSeconds: journal.hours * 3600, now: Date())
        guard commitJournal({ $0.sessions.append(log) }) else { return }
        state.session = FocusSession(profile: profile, locked: lockSession)
        showPlanner = false; runHook(.start); persist(); tick()
    }
    /// The Focus menu command and the global shortcut: plan or start a session, or stop the running one.
    func toggleFocus() { active ? stop() : start() }
    func stop() {
        guard !locked, workLog != nil else { return }
        // Early exits must leave an explanation just like any other unearned interruption.
        showPause = true
    }
    func pause(reason: String) {
        if changePhase(hook: .pause, { $0.pause(reason: reason, at: $1) }) { showPause = false }
    }
    /// Sleep pauses work or a break; time asleep is recorded as a pause either way.
    func pauseForSleep() {
        guard let phase = workLog?.phase, phase != .pause else { return }
        pause(reason: "Mac went to sleep")
        if let interval = workLog?.intervals.last, interval.kind == .pause { sleepPause = (interval.id, phase) }
    }
    /// Waking picks up where sleep left off, but only if sleep's pause is still the current interval:
    /// a pause you started, or anything you resumed or ended while the Mac slept, is left alone.
    /// A break goes back to being a break if there's break time left; otherwise work resumes.
    func resumeAfterWake() {
        guard let sleep = sleepPause else { return }
        sleepPause = nil
        guard let log = workLog, log.intervals.last?.id == sleep.id else { return }
        if sleep.phase == .break, log.breakBalance(at: Date()) >= 1 {
            changePhase(hook: .break) { log, now in log.transition(to: .break, at: now); return true }
        } else {
            resume()
        }
    }
    func takeBreak() {
        guard workLog != nil else { return }
        if !changePhase(hook: .break, { $0.takeBreak(at: $1) }), workLog != nil {
            message = "Work earns five minutes of break per hour. No break time is available yet."
        }
    }
    func resume() {
        guard let log = workLog, log.phase?.isFocused == false else { return }
        changePhase(hook: .resume) { log, now in log.transition(to: log.focusPhase(at: now), at: now); return true }
    }
    /// Brings the open session up to date, applies a phase change and, if it took effect, runs the hook and saves.
    @discardableResult private func changePhase(hook: HookEvent, _ change: (inout WorkLog, Date) -> Bool) -> Bool {
        guard let index = activeLogIndex else { return false }
        let now = Date()
        journal.sessions[index].advance(at: now)
        guard change(&journal.sessions[index], now) else { return false }
        if journal.sessions[index].phase?.isFocused != true { blocker.deactivate() }
        runHook(hook); persist(); return true
    }
    /// Adds a task to the running session. Returns false (with a message) if the title is blank or the link is invalid.
    @discardableResult func addTask(title: String, link: String = "") -> Bool {
        editTasks { $0.append(Todo().with(title: title, link: link)); return $0.count - 1 }
    }
    /// Renames or relinks a task in the running session. Invalid edits are rejected and leave the task unchanged.
    @discardableResult func updateTask(id: UUID, title: String, link: String) -> Bool {
        editTasks { todos in
            guard let index = todos.firstIndex(where: { $0.id == id }) else { return nil }
            todos[index] = todos[index].with(title: title, link: link); return index
        }
    }
    /// Marks a task in the running session done or not done.
    @discardableResult func setTaskCompleted(id: UUID, _ completed: Bool) -> Bool {
        guard let index = activeLogIndex else { return false }
        var todos = journal.sessions[index].todos
        guard let task = todos.firstIndex(where: { $0.id == id }) else { return false }
        todos[task].completed = completed
        return replaceTasks(todos, inSession: index)
    }
    /// Records an event on the running session, e.g. from `lockin event add`. Returns false if the text is blank.
    @discardableResult func addEvent(_ text: String) -> Bool {
        guard let index = activeLogIndex else { return false }
        var log = journal.sessions[index]
        guard log.addEvent(text, at: Date()) else { return false }
        return commitJournal { $0.sessions[index] = log }
    }
    /// Removes a task from the running session. Its record goes too: it won't appear in the review or journal.
    @discardableResult func deleteTask(id: UUID) -> Bool {
        guard let index = activeLogIndex, journal.sessions[index].todos.contains(where: { $0.id == id }) else { return false }
        return replaceTasks(journal.sessions[index].todos.filter { $0.id != id }, inSession: index)
    }
    /// Applies an edit to the running session's tasks; `edit` returns the index of the changed task.
    /// The edit is rejected if that task is invalid.
    private func editTasks(_ edit: (inout [Todo]) -> Int?) -> Bool {
        guard let index = activeLogIndex else { return false }
        var todos = journal.sessions[index].todos
        guard let changed = edit(&todos), todos[changed].hasTitle else { return false }
        guard todos[changed].validLink else { message = Todo.linkRequirement; return false }
        return replaceTasks(todos, inSession: index)
    }
    /// Saves a session's new task list, rolling back if the journal can't be written.
    private func replaceTasks(_ todos: [Todo], inSession index: Int) -> Bool {
        commitJournal { $0.sessions[index].todos = todos }
    }
    /// Used by Scripts/install-app.sh: pauses a working or break phase, remembers to resume after relaunch, then quits.
    /// A pause you started yourself is left alone. Hardcore Mode refuses, as it does for any quit.
    func quitForUpdate() {
        guard !locked else { message = "Hardcore Mode is active. Lock In can be updated when this session ends."; return }
        if let log = workLog, log.phase != .pause {
            pause(reason: "Updating Lock In")
            if let log = workLog {
                guard log.phase == .pause else { return }
                guard commitJournal({ $0.resumeAfterUpdateID = log.intervals.last?.id }) else { return }
            }
        }
        terminate()
    }
    /// Ends a session that has reached its target, overtime included, and opens the review.
    func finishSession() {
        guard let index = activeLogIndex else { return }
        now = Date()
        journal.sessions[index].advance(at: now)
        guard journal.sessions[index].complete(at: now) else { return }
        conclude(journal.sessions[index])
    }
    /// Closes the open session before its target so a fresh one can be planned (e.g. the next morning).
    func endSession(reason: String) {
        guard !locked, let index = activeLogIndex else { return }
        now = Date()
        journal.sessions[index].advance(at: now)
        guard journal.sessions[index].endEarly(reason: reason, at: now) else { return }
        // The review is presented once the end-session sheet has dismissed (see MainView); swapping sheets in one update is unreliable.
        conclude(journal.sessions[index], presentReview: !showEndSession)
    }
    private func conclude(_ log: WorkLog, presentReview: Bool = true) {
        runHook(.stop); state.session = nil; blocker.deactivate()
        journal.pendingReviewID = log.id; showReview = presentReview; showPause = false; showEndSession = false; page = .focus
        persist(); NSApp?.showMainWindow()
    }
    var activeLogIndex: Int? { journal.openSessionIndex }
    func tick() {
        now = Date()
        if let index = activeLogIndex {
            let previous = journal.sessions[index].phase
            journal.sessions[index].advance(at: now)
            let phase = journal.sessions[index].phase
            if phase != previous {
                // advance() only ends a spent break or moves work into overtime.
                if phase == .overtime && previous == .work {
                    runHook(.overtime); NSApp?.showMainWindow()
                } else {
                    runHook(.resume)
                }
                persist()
            } else if now.timeIntervalSince(lastCheckpoint) >= 10 {
                persist()
            }
        }
        if let session = state.session, workLog?.phase?.isFocused == true, enforceBlocking { blocker.enforce(profile: session.profile) }
        else { blocker.deactivate() }
    }
    /// Picks up the open session, or the review, where the last run left off.
    private func restoreSession(checkpoint: Date?) {
        if let index = activeLogIndex {
            if state.session == nil { state.session = FocusSession(profile: profile, locked: false) }
            // Time while the app was not running earns no credit. Preserve it as an interruption.
            if let checkpoint, Date().timeIntervalSince(checkpoint) > 15 {
                journal.sessions[index].advance(at: checkpoint)
                _ = journal.sessions[index].pause(reason: "App was not running; resumed from saved checkpoint", at: checkpoint)
            }
        } else if state.session != nil {
            // Enforcement without an open session, e.g. its file couldn't be read: nothing to enforce.
            state.session = nil
        }
        if let last = journal.sessions.last, last.endedAt != nil, !last.reviewed {
            journal.pendingReviewID = last.id
            state.session = nil
        }
        showReview = journal.pendingReviewID != nil
        if let pauseID = journal.resumeAfterUpdateID {
            journal.resumeAfterUpdateID = nil
            if workLog?.intervals.last?.id == pauseID { resume() } else { persist() }
        }
    }
    /// Saves ~/.lockin: settings, and each session file that changed. The open session's file is always written,
    /// since it carries the checkpoint.
    @discardableResult func persist() -> Bool {
        guard writable else { return false }
        do {
            try writer.write(preferences: state, journal: journal, checkpoint: Date())
            lastCheckpoint = Date()
        } catch { message = "Could not save to ~/.lockin: \(error.localizedDescription)"; return false }
        return true
    }
    /// Applies a journal change and saves it. If the change throws or the journal can't be written,
    /// the journal is put back as it was, so what's on screen always matches what's on disk.
    @discardableResult func commitJournal(_ change: (inout JournalState) throws -> Void) rethrows -> Bool {
        let previous = journal
        do { try change(&journal) } catch { journal = previous; throw error }
        guard persist() else { journal = previous; return false }
        return true
    }
    func completeReview() {
        guard let index = reviewIndex, journal.sessions[index].todos.allSatisfy(\.validLink) else { message = "Check the task links before saving."; return }
        let saved = commitJournal { journal in
            journal.setPlan(journal.sessions[index].rolledTodos)
            journal.sessions[index].reviewed = true
            journal.pendingReviewID = nil
        }
        if saved { showReview = false; showPlanner = true }
    }
    func setPassword(_ password: String) {
        guard !password.isEmpty else { return }
        let salt = UUID().uuidString
        updateProfile { $0.passwordSalt = salt; $0.passwordHash = Self.digest(password, salt: salt) }
        unlockedProfiles.remove(profile.id)
    }
    func unlock(_ password: String) {
        guard let salt = profile.passwordSalt, let hash = profile.passwordHash else { return }
        if Self.digest(password, salt: salt) == hash { unlockedProfiles.insert(profile.id) }
        else { message = "That password didn’t match." }
    }
    private static func digest(_ password: String, salt: String) -> String {
        // Repeated hashing slows offline guessing; this is a local preference gate, not a security boundary.
        var data = Data((salt + password).utf8)
        for _ in 0..<20_000 { data = Data(SHA256.hash(data: data)) }
        return data.base64EncodedString()
    }
    func runHook(_ event: HookEvent) {
        guard let session = state.session, let script = session.profile.hooks[event.rawValue], !script.isBlank else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            // LOCKIN_MODE is kept for existing hook scripts; every session is now a timed work target.
            "LOCKIN_EVENT": event.rawValue, "LOCKIN_PROFILE": session.profile.name, "LOCKIN_MODE": "Timer"
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { message = "Workflow failed to start: \(error.localizedDescription)" }
    }
    func handleURL(_ url: URL) {
        guard url.scheme == "lockin" else { return }
        switch url.host {
        case "start": start()
        case "stop", "pause": showPause = active
        case "finish": finishSession()
        case "break": takeBreak()
        case "resume": resume()
        case "update": quitForUpdate()
        default: break
        }
    }
}

enum MainWindow {
    static let id = "main"
}

extension OpenWindowAction {
    /// Opens (or focuses) the main window and brings Lock In forward, e.g. from the menu bar panel.
    @MainActor func main() {
        self(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension NSApplication {
    /// Brings Lock In forward with its main window, e.g. for a review or a pause prompt.
    func showMainWindow() {
        activate(ignoringOtherApps: true)
        windows.first { $0.identifier?.rawValue == MainWindow.id }?.makeKeyAndOrderFront(nil)
    }
}
