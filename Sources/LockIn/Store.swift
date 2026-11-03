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
    @Published var mode: SessionMode = .timer
    @Published var lockSession = false
    @Published var journal = JournalState()
    @Published var showPause = false
    @Published var showEndSession = false
    @Published var showReview = false
    @Published var showPlanner = false
    private var journalWritable = true
    private var lastCheckpoint = Date.distantPast
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
        case focus = "Focus", distractions = "Distractions", schedules = "Schedule", insights = "Insights", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .focus: return "scope"
            case .distractions: return "hand.raised"
            case .schedules: return "calendar"
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
    var locked: Bool { state.session?.locked == true }
    var canEdit: Bool { !locked && (profile.passwordHash == nil || unlockedProfiles.contains(profile.id)) && !active }
    var timerText: String {
        let seconds: Double
        if let log = workLog {
            seconds = log.phase == .break ? log.breakBalance(at: now) : log.remaining(at: now)
        } else { seconds = journal.hours * 3600 }
        return Self.clock(seconds)
    }
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    func save() {
        guard storageAvailable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: file, options: .atomic)
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
        state.profiles.removeAll { $0.id == id }; state.schedules.removeAll { $0.profileID == id }
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
    func start(profile: Profile? = nil, duration: TimeInterval? = nil, scheduledLock: Bool? = nil) {
        guard !active, storageAvailable, journalWritable else { return }
        now = Date()
        guard journal.pendingReviewID == nil else { showReview = true; return }
        let todos = journal.draft.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !todos.isEmpty else { showPlanner = true; message = "Add at least one task before starting."; return }
        guard todos.allSatisfy(\.validLink), journal.hours.isFinite, journal.hours > 0, journal.hours <= 24 else {
            message = "Use a work target between 0 and 24 hours and valid https://linear.app issue links."; return
        }
        let target = profile ?? self.profile
        let log = WorkLog(todos: todos, targetSeconds: journal.hours * 3600, now: Date())
        journal.sessions.append(log)
        guard persistJournal() else { journal.sessions.removeLast(); return }
        state.session = FocusSession(profile: target, mode: .timer, locked: scheduledLock ?? lockSession, now: log.startedAt, duration: log.targetSeconds)
        showPlanner = false; runHook("start"); save(); tick()
    }
    func stop() {
        guard !locked, workLog != nil else { return }
        // Early exits must leave an explanation just like any other unearned interruption.
        showPause = true
    }
    func pause(reason: String) {
        guard let index = activeLogIndex else { return }
        journal.sessions[index].advance(at: Date())
        guard journal.sessions[index].pause(reason: reason, at: Date()) else { return }
        showPause = false; syncSession(); blocker.deactivate(); runHook("pause"); persistJournal(); save()
    }
    func takeBreak() {
        guard let index = activeLogIndex else { return }
        journal.sessions[index].advance(at: Date())
        guard journal.sessions[index].takeBreak(at: Date()) else { message = "Work earns five minutes of break per hour. No break time is available yet."; return }
        syncSession(); blocker.deactivate(); runHook("break"); persistJournal(); save()
    }
    func resume() {
        guard let index = activeLogIndex, journal.sessions[index].phase != .work else { return }
        journal.sessions[index].advance(at: Date())
        journal.sessions[index].transition(to: .work, at: Date())
        syncSession(); runHook("resume"); persistJournal(); save()
    }
    /// Adds a task to the running session. Returns false (with a message) if the title is blank or the link is invalid.
    @discardableResult func addTask(title: String, linearURL: String = "") -> Bool {
        guard let index = activeLogIndex else { return false }
        var todo = Todo(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        todo.linearURL = linearURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !todo.title.isEmpty else { return false }
        guard todo.validLink else { message = "Use an https://linear.app issue URL."; return false }
        journal.sessions[index].todos.append(todo)
        guard persistJournal() else { journal.sessions[index].todos.removeLast(); return false }
        return true
    }
    /// Renames or relinks a task in the running session. Invalid edits are rejected and leave the task unchanged.
    @discardableResult func updateTask(id: UUID, title: String, linearURL: String) -> Bool {
        guard let index = activeLogIndex, let taskIndex = journal.sessions[index].todos.firstIndex(where: { $0.id == id }) else { return false }
        var todo = journal.sessions[index].todos[taskIndex]
        todo.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        todo.linearURL = linearURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !todo.title.isEmpty else { return false }
        guard todo.validLink else { message = "Use an https://linear.app issue URL."; return false }
        let previous = journal.sessions[index].todos[taskIndex]
        journal.sessions[index].todos[taskIndex] = todo
        guard persistJournal() else { journal.sessions[index].todos[taskIndex] = previous; return false }
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
    /// Closes the open session before its target so a fresh one can be planned (e.g. the next morning).
    func endSession(reason: String) {
        guard !locked, let index = activeLogIndex else { return }
        now = Date()
        journal.sessions[index].advance(at: now)
        if journal.sessions[index].endedAt == nil {
            guard journal.sessions[index].endEarly(reason: reason, at: now) else { return }
        }
        // The review is presented once the end-session sheet has dismissed (see MainView); swapping sheets in one update is unreliable.
        conclude(journal.sessions[index], presentReview: !showEndSession)
        showEndSession = false
    }
    private func conclude(_ log: WorkLog, presentReview: Bool = true) {
        runHook("stop"); state.session = nil; blocker.deactivate()
        journal.pendingReviewID = log.id; showReview = presentReview; showPause = false; showEndSession = false; page = .focus
        for interval in log.intervals where interval.kind == .work {
            state.records.append(FocusRecord(profileName: "Focus", start: interval.start, end: interval.end ?? now, completed: log.finishedNaturally))
        }
        persistJournal(); save(); NSApp?.activate(ignoringOtherApps: true)
        NSApp?.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
    }
    private var activeLogIndex: Int? { journal.sessions.lastIndex { $0.endedAt == nil } }
    private func syncSession() {
        guard let log = workLog, var session = state.session else { return }
        session.isBreak = log.phase != .work
        session.phaseStartedAt = log.intervals.last!.start
        session.deadline = log.phase == .pause ? nil : Date().addingTimeInterval(log.phase == .break ? log.breakBalance(at: Date()) : log.remaining(at: Date()))
        state.session = session
    }
    func tick() {
        now = Date()
        if let index = activeLogIndex {
            let previous = journal.sessions[index].phase
            journal.sessions[index].advance(at: now)
            let log = journal.sessions[index]
            if log.endedAt != nil {
                conclude(log)
            } else {
                syncSession()
                if log.phase != previous { runHook("resume"); persistJournal(); save() }
                if now.timeIntervalSince(lastCheckpoint) >= 10 { persistJournal(); save() }
            }
        }
        // A schedule prompts for a plan; it must never bypass task entry or the previous review.
        if !active && journal.pendingReviewID == nil {
            for schedule in state.schedules {
                guard let occurrence = schedule.occurrence(at: now), state.firedSchedules[schedule.id.uuidString] != occurrence else { continue }
                state.firedSchedules[schedule.id.uuidString] = occurrence
                showPlanner = true; page = .focus; save(); break
            }
        }
        if let session = state.session, workLog?.phase == .work, enforceBlocking { blocker.enforce(profile: session.profile) }
        else { blocker.deactivate() }
    }
    private func loadJournal() {
        let snapshot = journalDirectory.appendingPathComponent("state.json")
        do {
            if FileManager.default.fileExists(atPath: snapshot.path) {
                journal = try JSONDecoder().decode(JournalState.self, from: Data(contentsOf: snapshot))
            }
            if let log = workLog {
                if state.session == nil { state.session = FocusSession(profile: profile, mode: .timer, locked: false, now: log.startedAt, duration: log.targetSeconds) }
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
    @discardableResult func persistJournal() -> Bool {
        guard journalWritable else { return false }
        do {
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for log in journal.sessions {
                let name = "session-" + log.id.uuidString + ".yaml"
                try SessionYAML.encode(log, at: now).write(to: journalDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try encoder.encode(journal).write(to: journalDirectory.appendingPathComponent("state.json"), options: .atomic)
            lastCheckpoint = Date(); return true
        } catch { message = "Could not save session tracking in ~/.lockin: \(error.localizedDescription)"; return false }
    }
    func completeReview() {
        guard let index = reviewIndex, journal.sessions[index].todos.allSatisfy(\.validLink) else { message = "Check the Linear issue links before saving."; return }
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
        guard let session = state.session, let script = session.profile.hooks[event], !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LOCKIN_EVENT": event, "LOCKIN_PROFILE": session.profile.name, "LOCKIN_MODE": session.mode.rawValue
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { message = "Workflow failed to start: \(error.localizedDescription)" }
    }
    func handleURL(_ url: URL) {
        guard url.scheme == "lockin" else { return }
        switch url.host {
        case "start": start()
        case "stop", "pause": showPause = active
        case "break": takeBreak()
        case "resume": resume()
        case "update": quitForUpdate()
        default: break
        }
    }
}
