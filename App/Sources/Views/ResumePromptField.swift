import SwiftUI
import TicklerCore

/// The first message Claude gets when the session is resumed. Saved on Return or when the field loses focus.
struct ResumePromptField: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    @State private var text = ""
    @State private var loaded = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(text.isEmpty ? Color.secondary : Theme.accent)
            TextField(
                "Resume Prompt",
                text: $text,
                prompt: Text("What Claude should do on resume, e.g. compare ws-ports").foregroundStyle(.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            .onSubmit(commit)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.6) : .clear))
        .help("Sent to Claude as the first message when the session is reopened; typed without sending when it still runs.")
        .onAppear {
            text = reminder.resumePrompt ?? ""
            loaded = text
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                commit()
            }
        }
        .onDisappear(perform: commit)
        .onChange(of: reminder.resumePrompt) { _, newValue in
            if text == loaded {
                text = newValue ?? ""
            }
            loaded = newValue ?? ""
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard text != loaded, trimmed != (reminder.resumePrompt ?? "") else { return }
        loaded = text
        model.update(reminder.id, resumePrompt: trimmed)
    }
}
