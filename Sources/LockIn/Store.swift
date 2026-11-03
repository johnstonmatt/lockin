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
    private var journalWritable = true
    private var lastCheckpoint = Date.distantPast
    /// The YAML last written for each session, so finished sessions aren't rewritten on every checkpoint.
    private var writtenYAML: [UUID: String] = [:]
    private let journalDirectory: URL
    /// Replaceable so tests can exercise update handling without quitting the test runner.
    var terminate: () -> Void = { NSApp?.terminate(nil) }
    private let enforceBlocking: Bool
    var workLog: WorkLog? { journal.sessions.last(where: { $0.endedAt == nil }) }
    var reviewIndex: Int? { journal.sessions.firstIndex { $0.id == journal.pendingReviewID } }
    let blocker = Blocker()
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var storageAvailable = true
    private let file: URL
    enum Page: String, CaseIterable, Identifiable {
        case focus = "Focus", distractions = "Distractions", insights = "Insights", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .focus: return "scope"
            case .distractions: return "hand.raised"
            case .insights: return "chart.bar.xaxis"
            case .settings: return "slider.horizontal.3"
            }
        }
    }
    init(stateFile: URL? = nil, journalDirectory: URL? = nil, runTimer: Bool = true, enforceBlocking: Bool = true) {
        self.journalDirectory = journalDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lockin")
        self.enforceBlocking = enforceBlocking
        file = stateFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LockIn/state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file)) }
            catch { storageAvailable = false; message = "Could not read saved data. The original file is preserved. \(error.localizedDescription)" }
        }
        if state.profiles.isEmpty { state.profiles = [Profile()] }
        if !state.profiles.contains(where: { $0.id == state.selectedProfileID }) { state.selectedProfileID = state.profiles[0].id }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(reason: "Mac went to sleep") }
        }
        loadJournal()
        tick()
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
        guard let log = workLog else { return Self.clock(journal.hours * 3600) }
        if log.phase == .break { return Self.clock(log.breakBalance(at: now)) }
        // Past the target, the timer counts overtime up instead of work down.
        if log.targetReached(at: now) { return "+" + Self.clock(log.seconds(.overtime, at: now)) }
        return Self.clock(log.remaining(at: now))
    }
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    func save() {
        guard storageAvailable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(state).write(to: file, options: .atomic)
        } catch { message = "Could not save changes: \(error.localizedDescription)" }
    }
    func updateProfile(_ edit: (inout Profile) -> Void) {
        guard canEdit, let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        edit(&state.profiles[index]); save()
    }
    func select(_ id: UUID) { guard !active else { return }; state.selectedProfileID = id; save() }
    func addProfile() {
        guard !active else { return }
        let new = Profile(name: "New profile", symbol: "sparkles")
        state.profiles.append(new); state.selectedProfileID = new.id; save()
    }
    func deleteProfile() {
        guard canEdit, state.profiles.count > 1 else { return }
        let id = profile.id
        state.profiles.removeAll { $0.id == id }
        state.selectedProfileID = state.profiles[0].id; save()
    }
    func addWebsite(_ raw: String) {
        guard let rule = WebsiteRule.normalize(raw) else { message = "Enter a domain or website URL, such as reddit.com or youtube.com/shorts."; return }
        // Locked block lists can only become stricter. Allow lists cannot be expanded.
        if var session = state.session {
            guard session.profile.blockingMode == .block else { message = "Allow lists cannot be expanded during a session."; return }
            if !session.profile.websites.contains(rule) { session.profile.websites.append(rule) }
            state.session = session; save(); return
        }
        updateProfile { if !$0.websites.contains(rule) { $0.websites.append(rule) } }
    }
    func start() {
        guard !active, storageAvailable, journalWritable else { return }
        now = Date()
        guard journal.pendingReviewID == nil else { showReview = true; return }
        let todos = journal.draft.filter(\.hasTitle)
        guard !todos.isEmpty else { showPlanner = true; message = "Add at least one task before starting."; return }
        guard todos.allSatisfy(\.validLink), journal.hours.isFinite, journal.hours > 0, journal.hours <= 24 else {
            message = "Use a work target between 0 and 24 hours, and full web links (https://…) for tasks."; return
        }
        let log = WorkLog(todos: todos, targetSeconds: journal.hours * 3600, now: Date())
        journal.sessions.append(log)
        guard persistJournal() else { journal.sessions.removeLast(); return }
        state.session = FocusSession(profile: profile, locked: lockSession)
        showPlanner = false; runHook("start"); save(); tick()
    }
    func stop() {
        guard !locked, workLog != nil else { return }
        // Early exits must leave an explanation just like any other unearned interruption.
        showPause = true
    }
    func pause(reason: String) {
        if changePhase(hook: "pause", { $0.pause(reason: reason, at: $1) }) { showPause = false }
    }
    func takeBreak() {
        guard workLog != nil else { return }
        if !changePhase(hook: "break", { $0.takeBreak(at: $1) }), workLog != nil {
            message = "Work earns five minutes of break per hour. No break time is available yet."
        }
    }
    func resume() {
        guard let log = workLog, log.phase?.isFocused == false else { return }
        changePhase(hook: "resume") { log, now in log.transition(to: log.focusPhase(at: now), at: now); return true }
    }
    /// Brings the open session up to date, applies a phase change and, if it took effect, runs the hook and saves.
    @discardableResult private func changePhase(hook: String, _ change: (inout WorkLog, Date) -> Bool) -> Bool {
        guard let index = activeLogIndex else { return false }
        let now = Date()
        journal.sessions[index].advance(at: now)
        guard change(&journal.sessions[index], now) else { return false }
        if journal.sessions[index].phase?.isFocused != true { blocker.deactivate() }
        runHook(hook); saveAll(); return true
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
        let previous = journal.sessions[index].todos
        journal.sessions[index].todos = todos
        guard persistJournal() else { journal.sessions[index].todos = previous; return false }
        return true
    }
    /// Used by Scripts/install-app.sh: pauses a working or break phase, remembers to resume after relaunch, then quits.
    /// A pause you started yourself is left alone. Hardcore Mode refuses, as it does for any quit.
    func quitForUpdate() {
        guard !locked else { message = "Hardcore Mode is active. Lock In can be updated when this session ends."; return }
        if let log = workLog, log.phase != .pause {
            pause(reason: "Updating Lock In")
            if let log = workLog {
                guard log.phase == .pause else { return }
                journal.resumeAfterUpdateID = log.intervals.last?.id
                guard persistJournal() else { journal.resumeAfterUpdateID = nil; return }
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
        runHook("stop"); state.session = nil; blocker.deactivate()
        journal.pendingReviewID = log.id; showReview = presentReview; showPause = false; showEndSession = false; page = .focus
        saveAll(); NSApp?.showMainWindow()
    }
    private var activeLogIndex: Int? { journal.sessions.lastIndex { $0.endedAt == nil } }
    func tick() {
        now = Date()
        if let index = activeLogIndex {
            let previous = journal.sessions[index].phase
            journal.sessions[index].advance(at: now)
            let phase = journal.sessions[index].phase
            if phase != previous {
                // advance() only ends a spent break or moves work into overtime.
                if phase == .overtime && previous == .work {
                    runHook("overtime"); NSApp?.showMainWindow()
                } else {
                    runHook("resume")
                }
                saveAll()
            } else if now.timeIntervalSince(lastCheckpoint) >= 10 {
                saveAll()
            }
        }
        if let session = state.session, workLog?.phase?.isFocused == true, enforceBlocking { blocker.enforce(profile: session.profile) }
        else { blocker.deactivate() }
    }
    private func loadJournal() {
        let snapshot = journalDirectory.appendingPathComponent("state.json")
        do {
            if FileManager.default.fileExists(atPath: snapshot.path) {
                journal = try JSONDecoder().decode(JournalState.self, from: Data(contentsOf: snapshot))
            }
            if workLog != nil {
                if state.session == nil { state.session = FocusSession(profile: profile, locked: false) }
                // Time while the app was not running earns no credit. Preserve it as an interruption.
                if let checkpoint = try? FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date,
                   Date().timeIntervalSince(checkpoint) > 15 {
                    let index = activeLogIndex!
                    journal.sessions[index].advance(at: checkpoint)
                    _ = journal.sessions[index].pause(reason: "App was not running; resumed from saved checkpoint", at: checkpoint)
                }
            } else if state.session != nil {
                // Retain legacy history; old sessions cannot earn undocumented work credit.
                state.session = nil
            }
            if let last = journal.sessions.last, last.endedAt != nil, !last.reviewed {
                journal.pendingReviewID = last.id
                state.session = nil
            }
            showReview = journal.pendingReviewID != nil
            if let pauseID = journal.resumeAfterUpdateID {
                journal.resumeAfterUpdateID = nil
                if workLog?.intervals.last?.id == pauseID { resume() } else { persistJournal() }
            }
        } catch { journalWritable = false; message = "Could not read ~/.lockin/state.json. Original data is preserved. \(error.localizedDescription)" }
    }
    /// Saves both the session journal (~/.lockin) and preferences/session state.
    func saveAll() { persistJournal(); save() }
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()
    @discardableResult func persistJournal() -> Bool {
        guard journalWritable else { return false }
        do {
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            for log in journal.sessions {
                let yaml = SessionYAML.encode(log, at: now)
                guard writtenYAML[log.id] != yaml else { continue }
                try yaml.write(to: journalDirectory.appendingPathComponent("session-\(log.id).yaml"), atomically: true, encoding: .utf8)
                writtenYAML[log.id] = yaml
            }
            try Self.encoder.encode(journal).write(to: journalDirectory.appendingPathComponent("state.json"), options: .atomic)
            lastCheckpoint = Date(); return true
        } catch { message = "Could not save session tracking in ~/.lockin: \(error.localizedDescription)"; return false }
    }
    func completeReview() {
        guard let index = reviewIndex, journal.sessions[index].todos.allSatisfy(\.validLink) else { message = "Check the task links before saving."; return }
        let previous = journal
        journal.draft = journal.sessions[index].rolledTodos
        if journal.draft.isEmpty { journal.draft = [Todo()] }
        journal.sessions[index].reviewed = true
        journal.pendingReviewID = nil
        if persistJournal() { showReview = false; showPlanner = true } else { journal = previous }
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
    private func runHook(_ event: String) {
        guard let session = state.session, let script = session.profile.hooks[event], !script.isBlank else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            // LOCKIN_MODE is kept for existing hook scripts; every session is now a timed work target.
            "LOCKIN_EVENT": event, "LOCKIN_PROFILE": session.profile.name, "LOCKIN_MODE": "Timer"
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
