import SwiftUI
import Charts
import AppKit
import LockInCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "scope").font(.system(size: 26)).foregroundStyle(accent)
                    Text("Lock In").font(.system(size: 23, weight: .semibold, design: .rounded))
                }.padding(.top, 26).padding(.horizontal, 18)
                List(Store.Page.allCases, selection: $store.page) { page in
                    Label(page.rawValue, systemImage: page.icon).padding(.vertical, 8).tag(page)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Made for a quieter Mac", systemImage: "leaf")
                    Text("Local. Private. Yours.").font(.caption)
                }.font(.caption).foregroundStyle(.secondary).padding(20)
            }.navigationSplitViewColumnWidth(195)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.page.rawValue).font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(statusText, systemImage: store.active ? "circle.fill" : "shield.lefthalf.filled")
                            .font(.caption).foregroundStyle(accent).padding(10).background(accent.opacity(0.1), in: Capsule())
                    }
                    switch store.page {
                    case .focus: FocusView()
                    case .distractions: DistractionsView()
                    case .schedules: SchedulesView()
                    case .insights: InsightsView()
                    case .settings: PreferencesView()
                    }
                }.padding(32).frame(maxWidth: 950)
                    .frame(maxWidth: .infinity).clearsFieldFocusOnClick()
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $store.showPause) { PauseView().environmentObject(store).buttonStyle(.pointer(.automatic)) }
        .sheet(isPresented: $store.showEndSession, onDismiss: { if store.journal.pendingReviewID != nil { store.showReview = true } }) {
            EndSessionView().environmentObject(store).buttonStyle(.pointer(.automatic))
        }
        .sheet(isPresented: $store.showReview) { DayReviewView().environmentObject(store).buttonStyle(.pointer(.automatic)) }
        // Every button shows the pointing-hand cursor; explicit styles below wrap themselves in .pointer too.
        .buttonStyle(.pointer(.automatic))
        .tint(accent)
        .frame(minWidth: 820, minHeight: 610)
        .alert("Lock In", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
    private var statusText: String {
        switch store.workLog?.phase {
        case .work: return "Focusing"
        case .break: return "On a break"
        case .pause: return "Paused"
        case nil: return "Your time, protected"
        }
    }
    private var subtitle: String {
        switch store.page {
        case .focus: return "Make room for what matters."
        case .distractions: return "Choose what stays outside your focus time."
        case .schedules: return "Give your week a little structure."
        case .insights: return "Small sessions add up."
        case .settings: return "A routine that works for you."
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06)))
    }
}

struct FocusView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let log = store.workLog {
            Card {
                HStack { Text(log.phase == .work ? "Time to work" : log.phase == .break ? "Earned break" : "Paused").font(.title2); Spacer(); Text("Work target: \(log.targetSeconds / 3600, specifier: "%.2g") h").foregroundStyle(.secondary) }
                Text(store.timerText).font(.system(size: 58, weight: .light, design: .rounded)).monospacedDigit()
                ProgressView(value: min(log.seconds(.work, at: store.now), log.targetSeconds), total: log.targetSeconds).tint(.green)
                HStack {
                    Label("Break balance: " + Store.clock(log.breakBalance(at: store.now)), systemImage: "cup.and.saucer")
                    Spacer(); Text("5 min earned per hour worked").font(.caption).foregroundStyle(.secondary)
                }
                if log.phase == .pause { Text(log.intervals.last?.reason ?? "").foregroundStyle(.secondary) }
                SessionButtons(showStartNewDay: true)
            }
            Card {
                Text("This session’s tasks").font(.headline)
                ForEach(log.todos) { todo in SessionTaskRow(todo: todo) }
                AddSessionTask()
                Text("Mark tasks done and carry them forward in the completion review.").font(.caption).foregroundStyle(.secondary)
            }
        } else if store.journal.pendingReviewID != nil {
            Card { Text("Session complete").font(.title2); Text("Review your day and choose what comes next."); Button("Review day") { store.showReview = true }.buttonStyle(.pointer(.borderedProminent)) }
        } else {
            PlannerView()
        }
        ProtectionStatus(blocker: store.blocker)
    }
}

struct SessionTaskRow: View {
    @EnvironmentObject var store: Store
    let todo: Todo
    @State private var editing = false
    @State private var title = ""
    @State private var link = ""
    private var canSave: Bool { todo.with(title: title, link: link).hasTitle && Todo.isValidLink(link) }
    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Task", text: $title).textFieldStyle(.lockIn()).onSubmit(save)
                    TaskLinkField(link: $link, onSubmit: save)
                    Button(role: .destructive) { store.deleteTask(id: todo.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.pointer(.plain)).foregroundStyle(.red)
                        .help("Delete task").accessibilityLabel("Delete \(todo.title)")
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: save).buttonStyle(.pointer(.borderedProminent)).disabled(!canSave)
                }
                LinkRequirementNote(link: link)
            }
        } else {
            HStack {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle"); Text(todo.title); Spacer()
                TaskLinkBadge(todo: todo)
                Button { title = todo.title; link = todo.link; editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.pointer(.plain)).help("Edit task").accessibilityLabel("Edit \(todo.title)")
            }
        }
    }
    private func save() {
        guard canSave, store.updateTask(id: todo.id, title: title, link: link) else { return }
        editing = false
    }
}

struct AddSessionTask: View {
    @EnvironmentObject var store: Store
    @State private var title = ""
    @State private var link = ""
    private var canAdd: Bool { Todo().with(title: title, link: link).hasTitle && Todo.isValidLink(link) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add a task…", text: $title).textFieldStyle(.lockIn(icon: "plus")).onSubmit(add)
                TaskLinkField(link: $link, onSubmit: add)
                Button("Add", systemImage: "plus", action: add).disabled(!canAdd)
            }
            LinkRequirementNote(link: link)
        }
    }
    private func add() {
        guard canAdd, store.addTask(title: title, link: link) else { return }
        title = ""; link = ""
    }
}

struct SessionButtons: View {
    @EnvironmentObject var store: Store
    /// Only the main window offers ending a session early; the menu bar panel keeps to work/break/pause.
    var showStartNewDay = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 12) {
            if let log = store.workLog {
                if log.phase == .work {
                    Button("Take earned break") { store.takeBreak() }.disabled(log.breakBalance(at: store.now) < 1)
                    Button("Pause…") { store.showPause = true; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                } else {
                    Button("Resume work") { store.resume() }.buttonStyle(.pointer(.borderedProminent))
                    if log.phase == .break { Button("Pause instead…") { store.showPause = true; openWindow(id: "main") } }
                }
                if showStartNewDay {
                    Spacer()
                    Button("Start new day…", systemImage: "sunrise") { store.showEndSession = true }
                        .disabled(store.locked)
                        .help(store.locked ? "Hardcore Mode is active. The session must reach its target." : "End this session early, review it, and plan a new one.")
                }
            } else {
                Button(store.journal.pendingReviewID == nil ? "Plan your session" : "Review your day") {
                    store.page = .focus; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                    if store.journal.pendingReviewID != nil { store.showReview = true }
                }.buttonStyle(.pointer(.borderedProminent))
            }
        }.controlSize(.large)
    }
}

struct ProtectionStatus: View {
    @ObservedObject var blocker: Blocker
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(blocker.status, systemImage: blocker.needsAttention ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout).foregroundStyle(blocker.needsAttention ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(blocker.requestingPermission ? "Waiting for macOS…" : "Enable browser blocking") { blocker.requestBrowserAccess() }
                    .disabled(blocker.requestingPermission)
                if blocker.needsAttention {
                    Button("Automation settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                }
            }
        }
    }
}

struct DistractionsView: View {
    @EnvironmentObject var store: Store
    @State private var website = ""
    var body: some View {
        Card {
            HStack {
                Label("Websites", systemImage: "globe").font(.headline)
                Spacer()
                Picker("Mode", selection: Binding(get: { store.profile.blockingMode }, set: { value in store.updateProfile { $0.blockingMode = value } })) {
                    ForEach(BlockingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 150).disabled(!store.canEdit)
            }
            Text(store.profile.blockingMode == .block ? "Matching domains and their subdomains are blocked. You can include a path." : "All HTTP/S pages except these rules are blocked in supported browsers.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. reddit.com or youtube.com/shorts", text: $website).textFieldStyle(.lockIn(icon: "globe")).onSubmit(add)
                Button("Add", action: add).disabled(website.trimmingCharacters(in: .whitespaces).isEmpty)
            }.disabled(!store.canEdit && !(store.active && store.state.session?.profile.blockingMode == .block))
            ForEach(store.state.session?.profile.websites ?? store.profile.websites, id: \.self) { rule in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(rule).textSelection(.enabled)
                    Spacer()
                    Button { store.updateProfile { $0.websites.removeAll { $0 == rule } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.pointer(.plain)).disabled(!store.canEdit).accessibilityLabel("Remove \(rule)")
                }
                Divider()
            }
        }.dropDestination(for: String.self) { items, _ in items.forEach(store.addWebsite); return true }
        Card {
            HStack { Label("Applications", systemImage: "app.badge").font(.headline); Spacer(); Button("Add app…", action: chooseApp).disabled(!store.canEdit) }
            Text("Selected apps are hidden while focusing. They keep running so unsaved work is preserved.").font(.caption).foregroundStyle(.secondary)
            if store.profile.applications.isEmpty { Text("No applications added").foregroundStyle(.tertiary).padding(.vertical, 6) }
            ForEach(store.profile.applications) { app in
                HStack {
                    Text(app.name); Spacer()
                    Button { store.updateProfile { $0.applications.removeAll { $0.id == app.id } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.pointer(.plain)).disabled(!store.canEdit).accessibilityLabel("Remove \(app.name)")
                }
            }
        }
        Text("Browser coverage: Safari, Chrome, Brave, Edge, Vivaldi and Arc. The foreground browser tab is checked every 250 ms; background tabs are swept every two seconds. Firefox, downloads and other network traffic are not filtered.")
            .font(.caption).foregroundStyle(.secondary)
        ProtectionStatus(blocker: store.blocker)
    }
    private func add() { store.addWebsite(website); website = "" }
    private func chooseApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        guard id != Bundle.main.bundleIdentifier, !["com.apple.finder", "com.apple.systempreferences"].contains(id) else { store.message = "This app is needed to keep your Mac accessible."; return }
        let name = url.deletingPathExtension().lastPathComponent
        store.updateProfile { if !$0.applications.contains(where: { $0.id == id }) { $0.applications.append(BlockedApp(name: name, bundleID: id)) } }
    }
}
