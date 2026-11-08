import SwiftUI
import TicklerCore

/// The wrapping row under the title: when, how long, then the optional settings, filled when set and dashed when not.
struct DetailChipRow: View {
    let reminder: Reminder
    @Binding var editingDate: Bool
    let dateText: String

    var body: some View {
        let open = reminder.status == .open
        FlowLayout(spacing: 8, lineSpacing: 8) {
            WhenChip(reminder: reminder, editing: $editingDate, dateText: dateText)
            DurationChip(reminder: reminder)
            if open || reminder.holdsItsTime {
                FixedTimeChip(reminder: reminder)
            }
            if open || reminder.deadline != nil {
                DeadlineChip(reminder: reminder)
            }
            if reminder.autoRunMode != nil || (open && AutoRunChip.canOffer(reminder)) {
                AutoRunChip(reminder: reminder)
            }
            // Once or twice is the planner doing its job; from three it says the reminder keeps being pushed back.
            if reminder.rescheduleCount >= 3 {
                Text("rescheduled \(reminder.rescheduleCount)×")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.verdictWatch)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Pinned: the planner never moves it. A pin that comes from the auto-run or a fired trigger cannot be cleared here.
struct FixedTimeChip: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    private var lockReason: LocalizedStringKey? {
        if reminder.autoRun != nil {
            return "Pinned by its auto-run"
        }
        if reminder.firedAt != nil {
            return "Pinned by its fired trigger"
        }
        return nil
    }

    var body: some View {
        if reminder.holdsItsTime {
            Button { model.setFixed(reminder.id, false) } label: {
                ChipLabel(style: .neutral) {
                    Label("Fixed time", systemImage: "pin.fill").labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.plain)
            .disabled(lockReason != nil || reminder.status != .open)
            .help(lockReason ?? "Let the planner move it again")
        } else {
            Button { model.setFixed(reminder.id, true) } label: {
                ChipLabel(style: .dashed) { Text("+ fixed time") }
            }
            .buttonStyle(.plain)
            .help("Pin it: the planner never moves it")
            .accessibilityLabel(Text("Add a fixed time"))
        }
    }
}

/// "Before Mon 18:00": a date picker and Clear in a popover.
struct DeadlineChip: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var editing = false

    var body: some View {
        Group {
            if let deadline = reminder.deadline {
                Button { editing = true } label: {
                    ChipLabel(style: reminder.isLate ? .tinted(Theme.overdue) : .neutral) {
                        Text("Before \(Format.dueLabel(deadline, now: model.now))")
                    }
                }
                .buttonStyle(.plain)
                .disabled(reminder.status != .open)
                .help(reminder.isLate ? Text("Late for its deadline") : Text("Change the deadline"))
            } else {
                Button {
                    model.setDeadline(reminder.id, reminder.dueAt)
                    editing = true
                } label: {
                    ChipLabel(style: .dashed) { Text("+ deadline") }
                }
                .buttonStyle(.plain)
                .help("Set a deadline")
                .accessibilityLabel(Text("Add a deadline"))
            }
        }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            if let deadline = reminder.deadline {
                ReschedulePopover(
                    current: deadline,
                    confirmTitle: "Save",
                    clearTitle: "Clear the deadline",
                    onClear: {
                        editing = false
                        model.setDeadline(reminder.id, nil)
                    },
                    onFinish: { date in
                        editing = false
                        if let date {
                            model.setDeadline(reminder.id, date)
                        }
                    }
                )
            }
        }
    }
}

/// "Runs on its own: read only": the toggle and its mode open in a popover, with the reason it cannot be turned on.
struct AutoRunChip: View {
    let reminder: Reminder
    @State private var editing = false

    /// The chip is offered when a resume could run: a session or a folder.
    static func canOffer(_ reminder: Reminder) -> Bool {
        reminder.sessionId != nil || reminder.cwd != nil
    }

    var body: some View {
        Button { editing = true } label: {
            if let mode = reminder.autoRunMode {
                ChipLabel(style: .tinted(Theme.accent)) {
                    let title: LocalizedStringKey = mode == .read ? "Runs on its own: read only" : "Runs on its own: can modify"
                    Label(title, systemImage: "bolt.fill")
                }
            } else {
                ChipLabel(style: .dashed) { Text("+ auto-run") }
            }
        }
        .buttonStyle(.plain)
        .disabled(reminder.status != .open)
        .help("Run the resume prompt in the background when due")
        .accessibilityLabel(reminder.autoRunMode == nil ? Text("Add auto-run") : Text("Auto-run"))
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ReminderAutoRunToggle(reminder: reminder)
                if reminder.autoRunMode == nil, (reminder.resumePrompt ?? "").isEmpty || (reminder.cwd ?? "").isEmpty {
                    Text("Needs a resume prompt and a session folder").font(.caption).foregroundStyle(.secondary)
                }
                if reminder.autoRunMode != nil {
                    Text("Pinned by its auto-run").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}
