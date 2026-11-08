import SwiftUI
import TicklerCore

/// The words for a planner move, shared by the detail chip and the list marks.
enum MoveText {
    static func moved(_ move: ScheduleMove) -> String {
        let from = Format.dueLabel(move.from, now: Date())
        return String(localized: "Moved from \(from) (\(reason(move.reason)))")
    }

    static func reason(_ reason: MoveReason) -> String {
        switch reason {
        case .meeting: String(localized: "meeting")
        case .slotFreed: String(localized: "slot freed")
        case .dayFull: String(localized: "day full")
        case .reminderAdded: String(localized: "reminder added")
        case .settingsChanged: String(localized: "settings changed")
        case .migration: String(localized: "migration")
        case .replanned: String(localized: "replanned")
        }
    }
}

/// Small list marks: moved by the planner (unseen), overlapping a meeting it cannot leave, placed past its deadline.
struct ScheduleMarks: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        if reminder.status == .open {
            if let move = model.unseenMoves[reminder.id] {
                let reason = MoveText.reason(move.reason)
                mark("arrow.right.circle", label: String(localized: "Moved by the planner (\(reason))"))
            }
            if model.conflictedIds.contains(reminder.id) {
                mark("exclamationmark.triangle.fill", label: String(localized: "Conflicts with a meeting"), tint: Theme.overdue)
            }
            if reminder.isLate {
                mark("clock.badge.exclamationmark", label: String(localized: "Late for its deadline"), tint: Theme.overdue)
            }
        }
    }

    private func mark(_ symbol: String, label: String, tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
    }
}
