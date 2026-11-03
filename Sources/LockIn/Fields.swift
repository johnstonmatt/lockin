import SwiftUI
import AppKit
import LockInCore

let accent = Color(red: 0.25, green: 0.68, blue: 0.53)

/// Shared chrome for every text input: a soft fill that brightens on focus, a hairline border,
/// an accent ring while editing and a red ring when the content is invalid.
private struct FieldChrome<Content: View>: View {
    var icon: String?
    var invalid: Bool
    var multiline = false
    @ViewBuilder var content: (FocusState<Bool>.Binding) -> Content
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    private var ring: Color { invalid ? .red : focused ? accent : .primary.opacity(0.12) }
    var body: some View {
        HStack(alignment: multiline ? .top : .center, spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.callout).foregroundStyle(focused ? accent : .secondary).frame(width: 16)
            }
            content($focused)
        }
        .padding(.horizontal, multiline ? 5 : 10).padding(.vertical, multiline ? 6 : 7)
        .background(focused ? Color(nsColor: .textBackgroundColor) : .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ring, lineWidth: focused || invalid ? 1.5 : 1))
        .shadow(color: (invalid ? Color.red : accent).opacity(focused ? 0.22 : 0), radius: 5)
        .opacity(enabled ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { focused = true }
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: invalid)
    }
}

/// Use with `.textFieldStyle(.lockIn())`; applies to TextField and SecureField.
struct LockInFieldStyle: TextFieldStyle {
    var icon: String?
    var invalid = false
    func _body(configuration: TextField<Self._Label>) -> some View {
        // .plain strips AppKit's own bezel and blue focus ring, which otherwise draw inside this chrome.
        FieldChrome(icon: icon, invalid: invalid) { focus in configuration.textFieldStyle(.plain).focusEffectDisabled().focused(focus) }
    }
}

extension TextFieldStyle where Self == LockInFieldStyle {
    static func lockIn(icon: String? = nil, invalid: Bool = false) -> LockInFieldStyle { LockInFieldStyle(icon: icon, invalid: invalid) }
}

extension View {
    /// The multi-line counterpart of `LockInFieldStyle`, for TextEditor.
    func lockInEditor(invalid: Bool = false) -> some View {
        FieldChrome(icon: nil, invalid: invalid, multiline: true) { focus in
            self.scrollContentBackground(.hidden).focusEffectDisabled().focused(focus)
        }
    }
}

extension View {
    /// macOS keeps a text field focused when you click elsewhere. Clicking this container's non-interactive
    /// areas (background, cards, labels) ends editing; buttons and fields inside still get their own clicks.
    func clearsFieldFocusOnClick() -> some View {
        contentShape(Rectangle()).onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// The optional link field used wherever a task is entered.
struct TaskLinkField: View {
    @Binding var link: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField("Link: Linear, GitHub, Notion… (optional)", text: $link)
            .textFieldStyle(.lockIn(icon: "link", invalid: !Todo.isValidLink(link)))
            .onSubmit(onSubmit)
    }
}

/// A task's title and link fields on one row, followed by `actions` (e.g. Add, or Cancel and Save).
struct TaskForm<Actions: View>: View {
    @Binding var title: String
    @Binding var link: String
    let placeholder: String
    var icon: String?
    let onSubmit: () -> Void
    @ViewBuilder let actions: Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(placeholder, text: $title).textFieldStyle(.lockIn(icon: icon)).onSubmit(onSubmit)
                TaskLinkField(link: $link, onSubmit: onSubmit)
                actions
            }
            LinkRequirementNote(link: link)
        }
    }
}

/// Shown under a task's fields while its link isn't a usable web link.
struct LinkRequirementNote: View {
    let link: String
    var body: some View {
        if !Todo.isValidLink(link) { Text(Todo.linkRequirement).font(.caption).foregroundStyle(.red) }
    }
}

/// A task's link, named after the service it points to ("Linear ↗", "GitHub ↗", "Notion ↗"), or its site otherwise.
struct TaskLinkBadge: View {
    let todo: Todo
    var body: some View {
        if let url = todo.linkURL, let label = todo.linkLabel {
            // An explicit .link style, or the root .pointer(.automatic) would render the link as a bordered button.
            Link("\(label) ↗", destination: url).buttonStyle(.pointer(.link)).help(todo.link)
        }
    }
}
