import SwiftUI
import ServiceManagement
import LockInCore

struct SchedulesView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Card {
            HStack {
                Text("Your weekly routine").font(.headline); Spacer()
                Button("Add schedule", systemImage: "plus") {
                    store.state.schedules.append(Schedule(profileID: store.profile.id)); store.save()
                }.disabled(!store.canEdit)
            }
            if store.state.schedules.isEmpty {
                ContentUnavailableView("A little consistency", systemImage: "calendar.badge.clock", description: Text("Add a schedule to start focus automatically on the days you choose."))
            }
            ForEach($store.state.schedules) { $schedule in
                ScheduleRow(schedule: $schedule) {
                    store.state.schedules.removeAll { $0.id == schedule.id }; store.save()
                }.disabled(!store.canEdit)
                Divider()
            }
        }.onChange(of: store.state.schedules) { _, _ in store.save() }
        Text("Schedules remind you to plan a session. They never start work automatically or skip your task list and completion review.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct ScheduleRow: View {
    @Binding var schedule: Schedule
    var delete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Enabled", isOn: $schedule.enabled).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel("Delete schedule")
            }
            HStack {
                DatePicker("Start", selection: Binding(get: {
                    Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
                }, set: { date in
                    schedule.hour = Calendar.current.component(.hour, from: date)
                    schedule.minute = Calendar.current.component(.minute, from: date)
                }), displayedComponents: .hourAndMinute)
                Stepper("\(schedule.duration) min", value: $schedule.duration, in: 5...480, step: 5)
                Toggle("Hardcore", isOn: $schedule.locked).toggleStyle(.checkbox)
            }
            HStack(spacing: 7) {
                ForEach(1...7, id: \.self) { day in
                    Button(Calendar.current.shortWeekdaySymbols[day - 1]) {
                        if schedule.weekdays.contains(day) { schedule.weekdays.remove(day) } else { schedule.weekdays.insert(day) }
                    }.buttonStyle(.bordered).tint(schedule.weekdays.contains(day) ? .green : .gray)
                        .accessibilityValue(schedule.weekdays.contains(day) ? "Selected" : "Not selected")
                }
            }
        }.padding(.vertical, 8)
    }
}

struct PreferencesView: View {
    @EnvironmentObject var store: Store
    @State private var password = ""
    @State private var event = "start"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("showMenuBarCountdown") private var showMenuBarCountdown = false
    @State private var restoringMenuBarItem = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    var body: some View {
        Card {
            Label("Your rhythm", systemImage: "timer").font(.headline)
            Text("Set your work target when planning each session. Every hour of work earns five minutes of break; pauses require a written reason and do not spend your balance.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Session journals, TODOs, breaks and pauses are saved as YAML in ~/.lockin. A state.json file alongside them restores the app and your draft plan.").font(.caption).foregroundStyle(.secondary)
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
                Text("Focus starts").tag("start"); Text("Focus ends").tag("stop")
                Text("Break starts").tag("break"); Text("Focus resumes").tag("resume"); Text("Session pauses").tag("pause")
            }
            TextEditor(text: Binding(get: { store.profile.hooks[event] ?? "" }, set: { value in store.updateProfile { $0.hooks[event] = value } }))
                .font(.system(.body, design: .monospaced)).frame(height: 110).lockInEditor().disabled(!store.canEdit)
            Text("Optional shell commands run as your user through /bin/zsh. Available variables: LOCKIN_EVENT, LOCKIN_PROFILE, LOCKIN_MODE. Leave blank to do nothing.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { store.message = "Login setting failed: \(error.localizedDescription)" }
            }
            Text("Global shortcut: ⌃⌥⌘F · In Lock In: ⇧⌘F\nAutomation URLs: lockin://start · lockin://stop · lockin://break · lockin://resume")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            Text("About this build").font(.headline)
            Text("Native macOS app inspired by Focus 1.15. Settings and history stay on this Mac. Browser protection requires Automation permission and checks active tabs; it is not a network firewall. Apps are hidden, not terminated. Force-quitting Lock In bypasses protection. System-wide filtering, Firefox support and automatic Do Not Disturb are not included in this build.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func setting(_ key: WritableKeyPath<Profile, Int>) -> Binding<Int> {
        Binding(get: { store.profile[keyPath: key] }, set: { value in store.updateProfile { $0[keyPath: key] = value } })
    }
}
