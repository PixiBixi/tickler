import SwiftUI
import TicklerCore

/// "Run automatically when due" and its mode. Disabled while off when the reminder cannot run unattended.
struct AutoRunToggle: View {
    @Binding var mode: AutoRunMode?
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Run automatically when due", isOn: enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5))
                Text("AUTO")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            if mode != nil {
                Picker("Mode", selection: modeBinding) {
                    Text("Read only").tag(AutoRunMode.read)
                    Text("Can modify").tag(AutoRunMode.write)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
        }
        .disabled(mode == nil && !isAvailable)
        .help(mode == nil && !isAvailable ? "Needs a resume prompt and a session folder" : "")
    }

    private var enabled: Binding<Bool> {
        Binding(get: { mode != nil }, set: { mode = $0 ? .read : nil })
    }

    private var modeBinding: Binding<AutoRunMode> {
        Binding(get: { mode ?? .read }, set: { mode = $0 })
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
