import SwiftUI
import TicklerCore

/// What an event-driven reminder waits for, or why it fired. The live cards below show each link's state.
struct TriggerRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        if reminder.status == .open, let trigger = reminder.trigger {
            HStack(spacing: 8) {
                Label("Waiting for: \(trigger)", systemImage: "hourglass")
                Spacer()
                Button("Stop Waiting") { model.setTrigger(reminder.id, nil) }
                    .buttonStyle(.link)
                    .help("Keep the reminder at its date, without the event")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if reminder.status == .open, let reason = reminder.firedReason {
            Label(reason, systemImage: "bolt.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
