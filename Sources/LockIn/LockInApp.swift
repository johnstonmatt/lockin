import SwiftUI
import AppKit

@main struct LockInApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("showMenuBarCountdown") private var showMenuBarCountdown = false
    var body: some Scene {
        Window("Lock In", id: MainWindow.id) {
            MainView().environmentObject(store)
                .onAppear { delegate.connect(store) }
                .onOpenURL { store.handleURL($0) }
        }
        .defaultSize(width: 900, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Focus") {
                Button(store.active ? "Stop focusing" : "Start focusing") {
                    store.active ? store.stop() : store.start()
                }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(store.locked)
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
            shortcut = GlobalShortcut { [weak store] in
                guard let store else { return }
                store.active ? store.stop() : store.start()
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.locked == true {
            store?.message = "Hardcore Mode is active. Lock In can quit when this session ends."
            return .terminateCancel
        }
        if let store, let log = store.workLog, log.phase != .pause {
            store.showPause = true
            NSApp.showMainWindow()
            return .terminateCancel
        }
        store?.saveAll(); return .terminateNow
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 18) {
            HStack { Label("Lock In", systemImage: "scope").font(.headline); Spacer(); Text(store.active ? "ACTIVE" : "READY").font(.caption).foregroundStyle(.secondary) }
            Text(store.timerText).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
            Text(caption).foregroundStyle(.secondary)
            SessionButtons()
            Divider()
            HStack {
                Button("Open Lock In") { openWindow.main() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(store.locked)
            }.buttonStyle(.pointer(.plain))
        }.padding(22).frame(width: 310).tint(.mint).buttonStyle(.pointer(.automatic))
    }
    private var caption: String {
        switch store.workLog?.phase {
        case .pause: return "Paused · your reason is recorded"
        case .break: return "Enjoy your earned break."
        case .overtime: return "Overtime · target reached"
        case .work, nil: return "A little space for your best work."
        }
    }
}
