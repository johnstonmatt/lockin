import SwiftUI
import ServiceManagement
import LockInCore

struct PreferencesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updater: AppUpdater
    @State private var password = ""
    @State private var event = HookEvent.start
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("showMenuBarCountdown") private var showMenuBarCountdown = false
    @State private var restoringMenuBarItem = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var cliStatus = CommandLineTool.Status.notInstalled
    private var cliStatusText: String {
        switch cliStatus {
        case .unavailable: return "Only the packaged app includes the command line tool."
        case .notInstalled: return "Not installed."
        case .installed: return "lockin is linked to this copy of Lock In."
        case .linkedElsewhere(let path): return "lockin points to another copy (\(path)). Install to use this one."
        case .blocked: return "~/.local/bin/lockin is a file that isn't from Lock In. Remove it to install."
        }
    }
    var body: some View {
        Card {
            Label("Updates", systemImage: "arrow.down.circle").font(.headline)
            if let version = updater.currentVersion {
                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check for Updates…") { Task { await updater.check() } }.disabled(updater.busy)
                if updater.busy { ProgressView().controlSize(.small) }
                if updater.availableVersion != nil {
                    Button("Install update") { Task { await updater.install(locked: store.locked) } }
                        .disabled(updater.busy || store.locked || !updater.canInstall)
                }
            }
            Text(updater.status).font(.callout).textSelection(.enabled)
            if updater.availableVersion != nil {
                Text(!updater.canInstall ? "Install a packaged release to update from the app." : store.locked ? "Hardcore Mode blocks installation until this session ends." : "Installing restarts Lock In. Active sessions pause and resume automatically; a pause you started stays paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Card {
            Label("Your rhythm", systemImage: "timer").font(.headline)
            Text("Set your work target when planning each session. Every hour of work earns five minutes of break; pauses require a written reason and do not spend your balance.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Each session is saved as JSON in ~/.lockin/sessions, with its tasks, breaks, pauses and events. Profiles and your plan are in ~/.lockin/settings.json. The formats are documented as JSON Schemas in the Lock In repository.").font(.caption).foregroundStyle(.secondary)
        }
        Card {
            Label("Password protection", systemImage: "lock").font(.headline)
            Text("Protect preference changes with a password. Hardcore sessions cannot be unlocked with this password.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(store.profile.passwordHash == nil ? "Set a password" : "Password", text: $password).textFieldStyle(.lockIn(icon: "lock"))
                if store.profile.passwordHash == nil {
                    Button("Protect") { store.setPassword(password); password = "" }.disabled(password.isEmpty || !store.canEdit)
                } else if store.unlockedProfiles.contains(store.profile.id) {
                    Button("Lock preferences") { store.unlockedProfiles.remove(store.profile.id) }
                    Button("Remove password") { store.updateProfile { $0.passwordHash = nil; $0.passwordSalt = nil } }.disabled(!store.canEdit)
                } else {
                    Button("Unlock") { store.unlock(password); password = "" }.disabled(password.isEmpty || store.locked)
                }
            }
        }
        Card {
            Label("Workflows", systemImage: "terminal").font(.headline)
            Picker("Run script on", selection: $event) {
                ForEach(HookEvent.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextEditor(text: Binding(get: { store.profile.hooks[event.rawValue] ?? "" },
                                     set: { value in store.updateProfile { $0.hooks[event.rawValue] = value } }))
                .font(.system(.body, design: .monospaced)).frame(height: 110).lockInEditor().disabled(!store.canEdit)
            Text("Optional shell commands run as your user through /bin/zsh. Available variables: LOCKIN_EVENT, LOCKIN_PROFILE, LOCKIN_MODE. Leave blank to do nothing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Card {
            Label("Command line", systemImage: "apple.terminal").font(.headline)
            Text("The lockin command shows your status, pauses, takes breaks, edits tasks and backfills time from a terminal. Run lockin help for the rest.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(cliStatus == .installed ? "Installed" : "Install CLI", systemImage: "terminal") {
                    do { try CommandLineTool.install() } catch { store.message = error.localizedDescription }
                    cliStatus = CommandLineTool.status()
                }.disabled(cliStatus == .installed || cliStatus == .unavailable || cliStatus == .blocked)
                Text(cliStatusText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Installing links ~/.local/bin/lockin to this copy of Lock In. Add ~/.local/bin to your PATH if your shell doesn't already include it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { cliStatus = CommandLineTool.status() }
        Card {
            Label("General", systemImage: "gearshape").font(.headline)
            Toggle("Show Lock In in the menu bar", isOn: $showMenuBarItem)
            Toggle("Show countdown beside the menu-bar icon", isOn: $showMenuBarCountdown).disabled(!showMenuBarItem)
            HStack {
                Image(systemName: "scope")
                Text("Look for this icon on the right side of the menu bar.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore menu-bar icon") {
                restoringMenuBarItem = true
                showMenuBarItem = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    showMenuBarCountdown = false
                    showMenuBarItem = true
                    restoringMenuBarItem = false
                }
            }.disabled(restoringMenuBarItem)
            Text("If your menu bar is crowded, macOS or a menu-bar manager may hide icons. The compact icon uses less space than the countdown.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Launch at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                // Also reached when a failure below puts the toggle back to the real setting.
                guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch {
                    store.message = "Login setting failed: \(error.localizedDescription)"
                    loginEnabled = SMAppService.mainApp.status == .enabled
                }
            }
            Text("Global shortcut: ⌃⌥⌘F · In Lock In: ⇧⌘F\nAutomation URLs: lockin://start · lockin://stop · lockin://break · lockin://resume · lockin://finish")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            Text("About this build").font(.headline)
            Text("Settings and history stay on this Mac. Browser protection requires Automation permission and checks browser tabs; it is not a network firewall. Apps are hidden, not terminated. Force-quitting Lock In bypasses protection. System-wide filtering, Firefox support and automatic Do Not Disturb are not included in this build.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
