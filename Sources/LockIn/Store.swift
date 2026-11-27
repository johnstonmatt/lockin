import AppKit
import SwiftUI
import LockInCore

@MainActor final class Store: ObservableObject {
    @Published var state = SavedState()
    @Published var now = Date()
    @Published var message: String?
    @Published var unlockedProfiles: Set<UUID> = []
    @Published var page: Page = .focus
    @Published var lockSession = false
    @Published var journal = JournalState()
    @Published var workGraph = WorkGraph()
    var workImporting: Bool { workImportTask != nil }
    @Published var workImportMessage: String?
    var workGraphWritable = true
    @Published var workImportTask: Task<String, Error>?
    @Published var showPause = false
    @Published var showEndSession = false
    @Published var showReview = false
    /// False when saved data couldn't be read: saving over it would lose it, so nothing is saved until it's fixed.
    private var writable = true
    private var lastCheckpoint = Date.distantPast
    let directory: URL
    private let writer: StorageWriter
    /// Replaceable so tests can exercise update handling without quitting the test runner.
    var terminate: () -> Void = { NSApp?.terminate(nil) }
    private let enforceBlocking: Bool
    var workLog: WorkLog? { journal.openSession }
    /// Work can be added during a session, or to the plan once the last session is reviewed:
    /// saving the review replaces the plan, so earlier changes would be lost.
    var canPlanWork: Bool { workLog != nil || journal.pendingReviewID == nil }
    static let reviewFirstMessage = "Review your last session in Lock In before planning the next one."
    static let hardcoreQuitMessage = "Hardcore Mode is active. Lock In can quit or update once this session reaches its target."
    var reviewIndex: Int? { journal.sessions.firstIndex { $0.id == journal.pendingReviewID } }
    let blocker = Blocker()
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// The pause the Mac's sleep started and the phase it interrupted, so waking can pick up where sleep left off.
    private var sleepPause: (id: UUID, phase: WorkPhase)?
    private var remoteControl: RemoteControl?
    enum Page: String, CaseIterable, Identifiable {
        case focus = "Focus", work = "Work", distractions = "Distractions", history = "History", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .work: return "point.3.connected.trianglepath.dotted"
            case .focus: return "scope"
            case .distractions: return "hand.raised"
            case .history: return "chart.bar.xaxis"
            case .settings: return "slider.horizontal.3"
            }
        }
    }
    /// Reads Linear and GitHub for `addWork` and `importWork` unless a call passes its own importer.
    let importer: WorkImporter
    /// The time, replaceable so tests don't depend on how long they take.
    let clock: () -> Date
    /// `directory` is ~/.lockin in the app and a temporary directory in tests. `channel` is where `lockin` CLI
    /// commands arrive: `.app` in the app; tests pass nil, or a channel of their own, so they never answer the real
    /// CLI and the real app never answers them. Neither has a default, so a test can't reach the real ones by omission.
    init(directory: URL, runTimer: Bool = true, enforceBlocking: Bool = true, channel: RemoteChannel?,
         importer: WorkImporter = WorkConnections.importer, clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.importer = importer
        self.clock = clock
        now = clock()
        self.enforceBlocking = enforceBlocking
        var contents: Storage.Contents?
        do { contents = try Storage.load(from: directory) }
        catch { writable = false; message = "\(error.localizedDescription)\n\nLock In won't save anything until this is fixed, so the file is left as it is." }
        writer = StorageWriter(directory: directory, contents: contents ?? Storage.Contents())
        if let contents {
            state = contents.preferences; journal = contents.journal
            if !contents.skipped.isEmpty {
                message = "Some session files couldn't be read. They're left as they are and don't appear in History:\n" + contents.skipped.joined(separator: "\n")
            }
        }
        loadWorkGraph()
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
        attempt(normalizeSessionEntries)
        syncLocalWork()
        tick()
        if let channel { remoteControl = RemoteControl(store: self, channel: channel) }
        guard runTimer else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    /// Reads work-graph.json, or builds it from the journal's tasks when there isn't one yet.
    private func loadWorkGraph() {
        do {
            if let graph = try Storage.loadWorkGraph(from: directory) { workGraph = graph; return }
            let current = journal.openSession?.todos ?? []
            let review = journal.sessions.first { $0.id == journal.pendingReviewID }?.todos ?? []
            workGraph = WorkGraph.migrating(journal.draft + current + review)
            if !workGraph.nodes.isEmpty { try Storage.saveWorkGraph(workGraph, in: directory) }
        } catch {
            workGraphWritable = false
            workImportMessage = "\(error.localizedDescription) Work can't be changed until this is fixed, so the file is left as it is."
        }
    }
    var profile: Profile { state.profiles.first { $0.id == state.selectedProfileID } ?? state.profiles[0] }
    var active: Bool { state.session != nil }
    /// Hardcore Mode holds until the work target is reached; overtime can be ended, quit or updated freely.
    var locked: Bool { WorkLog.hardcoreHolds(locked: state.session?.locked == true, session: workLog, at: now) }
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
    /// During a session only a block list can grow, as it only gets stricter; otherwise the profile must be editable.
    var canAddWebsite: Bool { state.session.map { $0.profile.blockingMode == .block } ?? canEdit }
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
        now = clock()
        guard journal.pendingReviewID == nil else { presentReview(); return }
        let todos = journal.plannedTasks
        guard todos.allSatisfy(\.validLink), JournalState.isValidTarget(hours: journal.hours) else {
            message = "Use a work target between 0 and 24 hours, and full web links (https://…) for tasks."; return
        }
        let log = WorkLog(todos: todos, targetSeconds: journal.hours * 3600, now: clock())
        guard attempt({ try commitJournal { $0.sessions.append(log) } }) else { return }
        state.session = FocusSession(profile: profile, locked: lockSession)
        runHook(.start); persist(); tick()
    }
    /// The Focus menu command and the global shortcut: start a session, or ask why you're pausing the running one.
    func toggleFocus() { active ? requestPause() : start() }
    /// Asks for a pause reason: every interruption leaves an explanation. Hardcore Mode allows pauses, since they
    /// are recorded; it only holds the session open until its target.
    func requestPause() {
        guard workLog != nil else { return }
        showPause = true; NSApp?.showMainWindow()
    }
    /// Brings up the pending review in the main window.
    func presentReview() {
        guard journal.pendingReviewID != nil else { return }
        page = .focus; showReview = true; NSApp?.showMainWindow()
    }
    /// Whether Lock In can quit now. Hardcore Mode refuses until the target is reached; a running work or break
    /// phase asks for a pause reason first, so the time away is recorded.
    func shouldQuit() -> Bool {
        if locked { message = Self.hardcoreQuitMessage; return false }
        if let log = workLog, log.phase != .pause { requestPause(); return false }
        persist(); return true
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
        if sleep.phase == .break, log.breakBalance(at: clock()) >= 1 {
            changePhase(hook: .break) { log, now in log.transition(to: .break, at: now); return true }
        } else {
            resume()
        }
    }
    func takeBreak() {
        guard workLog != nil else { return }
        if !changePhase(hook: .break, { $0.takeBreak(at: $1) }), workLog != nil {
            message = "Work earns \(WorkLog.breakRateText). No break time is available yet."
        }
    }
    func resume() {
        guard let log = workLog, log.phase?.isFocused == false else { return }
        changePhase(hook: .resume) { log, now in log.transition(to: log.focusPhase(at: now), at: now); return true }
    }
    /// Brings the open session up to date, applies a phase change and, if it took effect, runs the hook and saves.
    @discardableResult private func changePhase(hook: HookEvent, _ change: (inout WorkLog, Date) -> Bool) -> Bool {
        guard let index = journal.openSessionIndex else { return false }
        let now = clock()
        journal.sessions[index].advance(at: now)
        guard change(&journal.sessions[index], now) else { return false }
        if journal.sessions[index].phase?.isFocused != true { blocker.deactivate() }
        runHook(hook); persist(); return true
    }
    /// Records an event on the running session, e.g. from `lockin event add`.
    func addEvent(_ text: String) throws {
        guard let index = journal.openSessionIndex else { throw LockInError("No session is running. Events are recorded on the running session.") }
        var log = journal.sessions[index]
        guard log.addEvent(text, at: clock()) else { throw LockInError("An event needs some text.") }
        try commitJournal { $0.sessions[index] = log }
    }
    /// `lockin://update`, sent by Scripts/install.sh (and so by `lockin upgrade`): pauses a working or break phase,
    /// remembers to resume after relaunch, then quits.
    /// A pause you started yourself is left alone. Hardcore Mode refuses, as it does for any quit.
    func quitForUpdate() {
        guard !locked else { message = Self.hardcoreQuitMessage; return }
        if let log = workLog, log.phase != .pause {
            pause(reason: "Updating Lock In")
            if let log = workLog {
                guard log.phase == .pause else { return }
                guard attempt({ try commitJournal { $0.resumeAfterUpdateID = log.intervals.last?.id } }) else { return }
            }
        }
        terminate()
    }
    /// Ends a session that has reached its target, overtime included, and opens the review.
    func finishSession() {
        guard let index = journal.openSessionIndex else { return }
        now = clock()
        journal.sessions[index].advance(at: now)
        guard journal.sessions[index].complete(at: now) else { return }
        conclude(journal.sessions[index])
    }
    /// Closes the open session before its target so a fresh one can be planned (e.g. the next morning).
    func endSession(reason: String) {
        guard !locked, let index = journal.openSessionIndex else { return }
        now = clock()
        journal.sessions[index].advance(at: now)
        guard journal.sessions[index].endEarly(reason: reason, at: now) else { return }
        // The review is presented once the end-session sheet has dismissed (see MainView); swapping sheets in one update is unreliable.
        conclude(journal.sessions[index], presentReview: !showEndSession)
    }
    private func conclude(_ log: WorkLog, presentReview present: Bool = true) {
        runHook(.stop); state.session = nil; blocker.deactivate()
        journal.pendingReviewID = log.id; showPause = false; showEndSession = false
        persist()
        if present { presentReview() } else { page = .focus; NSApp?.showMainWindow() }
    }
    func tick() {
        now = clock()
        if let index = journal.openSessionIndex {
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
        if let index = journal.openSessionIndex {
            if state.session == nil { state.session = FocusSession(profile: profile, locked: false) }
            // Time while the app was not running earns no credit. Preserve it as an interruption.
            if let checkpoint, clock().timeIntervalSince(checkpoint) > 15 {
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
    func save() throws {
        guard writable else { throw LockInError("Lock In isn't saving anything until the problem reading ~/.lockin is fixed.") }
        do { try writer.write(preferences: state, journal: journal, checkpoint: clock()) }
        catch { throw LockInError("Could not save to ~/.lockin: \(error.localizedDescription)") }
        lastCheckpoint = clock()
    }
    /// `save` where the failure can only be shown in the window. While saved data is unreadable, that problem's
    /// message stays on screen instead.
    @discardableResult func persist() -> Bool { writable && attempt(save) }
    /// Runs `body`, showing its error in the window if it throws.
    @discardableResult func attempt(_ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch { message = error.localizedDescription; return false }
    }
    /// Applies a journal change and saves it. If the change throws or the journal can't be written,
    /// the journal is put back as it was, so what's on screen always matches what's on disk.
    func commitJournal(_ change: (inout JournalState) throws -> Void) throws {
        let previous = journal
        do {
            try change(&journal)
            journal.normalizeWorkEntries(using: workGraph)
            try save()
        } catch { journal = previous; throw error }
        syncLocalWork()
    }
    /// The plan's work target, saved as it's edited.
    var plannedHours: Double {
        get { journal.hours }
        set { if newValue.isFinite { attempt { try commitJournal { $0.hours = newValue } } } }
    }
    /// The pending review's tasks, saved as they're edited so a review survives quitting.
    var reviewTasks: [Todo] {
        get { reviewIndex.map { journal.sessions[$0].todos } ?? [] }
        set {
            guard let index = reviewIndex else { return }
            attempt { try commitJournal { $0.sessions[index].todos = newValue } }
        }
    }
    func completeReview() {
        guard let index = reviewIndex, journal.sessions[index].todos.allSatisfy(\.validLink) else { message = "Check the task links before saving."; return }
        let saved = attempt {
            try commitJournal { journal in
                journal.setPlan(journal.sessions[index].rolledTodos)
                journal.sessions[index].reviewed = true
                journal.pendingReviewID = nil
            }
        }
        if saved { showReview = false }
    }
    func setPassword(_ password: String) {
        guard !password.isEmpty else { return }
        updateProfile { $0.setPassword(password) }
        unlockedProfiles.remove(profile.id)
    }
    func unlock(_ password: String) {
        guard profile.passwordHash != nil else { return }
        if profile.passwordMatches(password) { unlockedProfiles.insert(profile.id) }
        else { message = "That password didn’t match." }
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
        case "stop", "pause": requestPause()
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
