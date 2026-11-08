import SwiftUI
import TicklerCore

/// "Run automatically when due" and its mode. Disabled while off when the reminder cannot run unattended.
struct AutoRunToggle: View {
    @Binding var mode: AutoRunMode?
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(mode == nil ? Color.secondary : Theme.accent)
                Text("Run automatically when due").font(.system(size: 12.5))
                Spacer(minLength: 8)
                Toggle("Run automatically when due", isOn: enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if let current = mode {
                // Outlined like the other buttons; the native segmented control clashed with them.
                HStack(spacing: 8) {
                    modeButton("Read only", systemImage: "eye", value: .read, selected: current == .read)
                    modeButton("Can modify", systemImage: "pencil", value: .write, selected: current == .write)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .disabled(mode == nil && !isAvailable)
        .help(mode == nil && !isAvailable ? "Needs a resume prompt and a session folder" : "")
    }

    private var enabled: Binding<Bool> {
        Binding(get: { mode != nil }, set: { mode = $0 ? .read : nil })
    }

    private func modeButton(_ title: LocalizedStringKey, systemImage: String, value: AutoRunMode, selected: Bool) -> some View {
        Button { mode = value } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.12))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The detail pane's toggle, written straight to the reminder.
struct ReminderAutoRunToggle: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        AutoRunToggle(
            mode: Binding(
                get: { reminder.autoRunMode },
                set: { model.setAutoRun(reminder.id, $0) }
            ),
            isAvailable: !(reminder.resumePrompt ?? "").isEmpty && !(reminder.cwd ?? "").isEmpty
        )
    }
}
