import SwiftUI
import LockInCore

struct TodoEditor: View {
    @Binding var todo: Todo
    var review = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if review { Toggle("Done", isOn: $todo.completed).toggleStyle(.checkbox) }
                TextField("What are you working on?", text: $todo.title).textFieldStyle(.lockIn())
            }
            HStack {
                TaskLinkField(link: $todo.link)
                if review { Toggle("Next session", isOn: $todo.rollForward).toggleStyle(.checkbox) }
            }
            LinkRequirementNote(link: todo.link)
        }.padding(.vertical, 6)
    }
}
struct PlannerView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Card {
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day()).font(.subheadline).foregroundStyle(.secondary)
            Text("What are you working on today?").font(.title2)
            ForEach($store.journal.draft) { $todo in
                HStack(alignment: .top) {
                    TodoEditor(todo: $todo)
                    Button { store.journal.draft.removeAll { $0.id == todo.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.pointer(.plain)).padding(.top, 12).accessibilityLabel("Remove task")
                }
            }
            Button("Add task", systemImage: "plus") { store.journal.draft.append(Todo()) }
            Divider()
            HStack {
                Text("Hours of work")
                TextField("Hours", value: $store.journal.hours, format: .number).multilineTextAlignment(.center).textFieldStyle(.lockIn()).frame(width: 80)
                Stepper("", value: $store.journal.hours, in: 0.25...24, step: 0.25).labelsHidden()
                Spacer()
                Text("2 hours earns 10 minutes of break").font(.caption).foregroundStyle(.secondary)
            }
            Text("The timer counts work only. Breaks and justified pauses extend the session. Earned break time belongs to this session and does not carry forward.").font(.caption).foregroundStyle(.secondary)
            Toggle("Hardcore Mode", isOn: $store.lockSession).toggleStyle(.checkbox)
            Button("Start session", systemImage: "play.fill") { store.start() }.buttonStyle(.pointer(.borderedProminent)).controlSize(.large)
        }
        // Every draft edit, including adding and removing tasks, is saved here.
        .onChange(of: store.journal.draft) { _, _ in store.persist() }
        .onChange(of: store.journal.hours) { _, value in if value.isFinite { store.persist() } }
    }
}
struct PauseView: View {
    @EnvironmentObject var store: Store
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Why are you pausing?", systemImage: "pause.circle").font(.title2)
            Text("Pauses don’t spend earned break time. Your reason and the time away will be saved in the session journal.").foregroundStyle(.secondary)
            TextEditor(text: $reason).frame(height: 100).lockInEditor()
            HStack { Button("Cancel") { store.showPause = false }; Spacer(); Button("Pause session") { store.pause(reason: reason) }.buttonStyle(.pointer(.borderedProminent)).disabled(reason.isBlank) }
        }.padding(28).frame(width: 480).clearsFieldFocusOnClick()
    }
}
struct EndSessionView: View {
    @EnvironmentObject var store: Store
    @State private var reason = "Starting a new day"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Start a new day?", systemImage: "sunrise").font(.title2)
            if let log = store.workLog {
                Text("This ends the current session with \(WorkStats.clock(log.remaining(at: store.now))) of its work target left. You’ll review it, choose which tasks carry forward, then plan a fresh session.").foregroundStyle(.secondary)
            }
            Text("Reason (saved in the session journal)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $reason).frame(height: 80).lockInEditor()
            HStack {
                Button("Cancel") { store.showEndSession = false }
                Spacer()
                Button("End session & review") { store.endSession(reason: reason) }.buttonStyle(.pointer(.borderedProminent))
                    .disabled(reason.isBlank)
            }
        }.padding(28).frame(width: 480).clearsFieldFocusOnClick()
    }
}
struct DayReviewView: View {
    @EnvironmentObject var store: Store
    private var day: Date { store.reviewIndex.map { store.journal.sessions[$0].lastActiveAt } ?? store.now }
    private var stats: WorkStats { WorkStats(sessions: store.journal.sessions, now: store.now) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your day, in focus").font(.largeTitle)
            Text(day, format: .dateTime.weekday(.wide).month().day()).foregroundStyle(.secondary)
            let range = stats.day(containing: day)
            DayTimeline(intervals: stats.intervals(in: range), events: stats.events(in: range), now: store.now)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let index = store.reviewIndex {
                        Text("Update your TODOs").font(.headline)
                        Text("Choose “Next session” for each task you want to carry forward. It will be copied into the next plan; this session’s record stays intact.").font(.caption).foregroundStyle(.secondary)
                        ForEach($store.journal.sessions[index].todos) { $todo in TodoEditor(todo: $todo, review: true) }
                        Button("Add task", systemImage: "plus") { store.journal.sessions[index].todos.append(Todo()) }
                    }
                }
            }.frame(minHeight: 140)
            HStack { Text("Saved locally in ~/.lockin").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save & plan next session") { store.completeReview() }.buttonStyle(.pointer(.borderedProminent)) }
        }.padding(28).frame(width: 720, height: 660).clearsFieldFocusOnClick()
        .interactiveDismissDisabled()
        .onChange(of: store.reviewIndex.map { store.journal.sessions[$0].todos } ?? []) { _, _ in store.persist() }
    }
}
