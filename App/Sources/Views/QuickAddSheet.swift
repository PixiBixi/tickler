import SwiftUI
import TicklerCore

struct QuickAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var when = ""
    @State private var notes = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let parsed = DateParser(preferred: Format.locale.language.languageCode?.identifier ?? "en").parse(when)
        VStack(alignment: .leading, spacing: 14) {
            Text("New Reminder").font(.system(size: 15, weight: .semibold))
            TextField("What needs doing", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            VStack(alignment: .leading, spacing: 4) {
                TextField("When: tomorrow 9:30, lundi 10h, in 2h", text: $when)
                    .textFieldStyle(.roundedBorder)
                Group {
                    if let parsed {
                        Text(Format.dueLabel(parsed, now: Date())).foregroundStyle(Theme.accent)
                    } else if when.isEmpty {
                        Text("Type a day and a time.").foregroundStyle(.secondary)
                    } else {
                        Text("Not understood yet.").foregroundStyle(Theme.overdue)
                    }
                }
                .font(.system(size: 12))
            }
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .frame(height: 100)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let parsed {
                        model.add(title: title.trimmingCharacters(in: .whitespaces), notes: notes, dueAt: parsed)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { titleFocused = true }
    }
}
