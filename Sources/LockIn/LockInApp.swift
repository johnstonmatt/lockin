import SwiftUI
import AppKit
import LockInCore

@main struct LockInApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store(directory: Storage.directory, channel: .app)
    @StateObject private var updater = AppUpdater()
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarSettings.showItem) private var showMenuBarItem = true
    @AppStorage(MenuBarSettings.showCountdown) private var showMenuBarCountdown = false
    var body: some Scene {
        Window("Lock In", id: MainWindow.id) {
            MainView().environmentObject(store).environmentObject(updater)
                .onAppear { delegate.connect(store) }
                .onOpenURL { store.handleURL($0) }
        }
        .defaultSize(width: 900, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    store.page = .settings
                    openWindow.main()
                    Task { await updater.check() }
                }.disabled(updater.busy)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Focus") {
                Button(store.active ? "Stop focusing" : "Start focusing") { store.toggleFocus() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuPanel().environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scope")
                if showMenuBarCountdown && store.active { Text(store.timerText).monospacedDigit() }
            }
            .accessibilityLabel("Lock In")
            .help(store.active ? "Lock In · " + store.timerText : "Lock In · Plan a focus session")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    private var shortcut: GlobalShortcut?
    func connect(_ store: Store) {
        self.store = store
        if shortcut == nil {
            shortcut = GlobalShortcut { [weak store] in store?.toggleFocus() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.shouldQuit() == false ? .terminateCancel : .terminateNow
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 18) {
            HStack { Label("Lock In", systemImage: "scope").font(.headline); Spacer(); Text(store.active ? "ACTIVE" : "READY").font(.caption).foregroundStyle(.secondary) }
            Text(store.timerText).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
            Text(WorkPhase.caption(store.workLog?.phase)).foregroundStyle(.secondary)
            SessionButtons()
            Divider()
            HStack {
                Button("Open Lock In") { openWindow.main() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(store.locked)
            }.buttonStyle(.pointer(.plain))
        }.padding(22).frame(width: 310).tint(accent).buttonStyle(.pointer(.automatic))
    }
}
