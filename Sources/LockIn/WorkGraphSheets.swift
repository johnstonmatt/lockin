import SwiftUI
import LockInCore

struct WorkConnectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connections").font(.title2.weight(.semibold))
            Text("Linear").font(.headline)
            Text(hasKey ? "A personal API key is saved in macOS Keychain." : "Add a personal API key with read access to the teams you work with.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField(hasKey ? "Replace API key" : "Personal API key", text: $key).textFieldStyle(.lockIn(icon: "key"))
            HStack {
                Link("Create a key in Linear", destination: URL(string: "https://linear.app/settings/account/security")!)
                Spacer()
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        do { try LinearCredential.remove(); hasKey = false; message = "Key removed." }
                        catch { message = error.localizedDescription }
                    }
                }
                Button("Save key") {
                    do { try LinearCredential.save(key); key = ""; hasKey = true; message = "Key saved in Keychain." }
                    catch { message = error.localizedDescription }
                }.disabled(key.trimmed.isEmpty)
            }
            Divider()
            Text("GitHub").font(.headline)
            Text("Uses your GitHub CLI sign-in to read PRs and stacks. Install gh and run gh auth login in Terminal. No repository checkout is needed.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Connections are read-only. Sequencing edits and session completion stay in Lock In.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 510)
            .onAppear {
                do { hasKey = try LinearCredential.read() != nil }
                catch { message = error.localizedDescription }
            }
    }
}

struct AddGraphWorkView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.workLog == nil ? "Add work to the next session" : "Add work to this session")
                .font(.title2.weight(.semibold))
            TextField("Paste a URL or enter a task name", text: $input)
                .textFieldStyle(.lockIn(icon: "plus"))
                .focused($focused)
                .onSubmit(add)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(error == nil ? Color.clear : Color.red, lineWidth: 1))
                .onChange(of: input) { error = nil }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .accessibilityLabel(error)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add work", action: add)
                    .disabled(input.trimmed.isEmpty || store.workImporting)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 510)
        .onAppear { focused = true }
    }

    private func add() {
        do {
            try store.addWork(input)
            dismiss()
        } catch {
            withAnimation(.easeInOut(duration: 0.15)) { self.error = error.localizedDescription }
            NSSound.beep()
            focused = true
        }
    }
}
