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

/// One line under the result, one column only: the session, its auto-run mode as a menu, and Reopen.
struct AutoRunSessionStrip: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    /// A background run holds the session: Reopen is refused.
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(model.finishedRun(for: reminder)?.tint ?? Color.secondary).frame(width: 7, height: 7)
            Text("Session").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            if let sessionId = reminder.sessionId {
                Text(verbatim: sessionId)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sessionId)
            }
            Divider().frame(height: 14)
            modeMenu
            Spacer(minLength: 8)
            Button { model.resume(reminder) } label: {
                Label("Reopen", systemImage: "terminal").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modeMenu: some View {
        Menu {
            Button("Read only") { model.setAutoRun(reminder.id, .read) }
            Button("Can modify") { model.setAutoRun(reminder.id, .write) }
            Divider()
            Button("Turn off auto-run") { model.setAutoRun(reminder.id, nil) }
        } label: {
            Group {
                if reminder.autoRunMode == .write {
                    Label("AUTO · can modify", systemImage: "bolt.fill")
                } else {
                    Label("AUTO · read only", systemImage: "bolt.fill")
                }
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
