import Foundation
import TicklerCore

@MainActor
extension AppModel {
    /// Unseen moves are those of today and yesterday: older ones are history, not news.
    func loadScheduleMarks(store: ReminderStore) {
        let since = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        let moves = (try? store.moves(since: since, includeMigration: false)) ?? []
        // Moves come oldest first: the last one of a reminder wins.
        unseenMoves = Dictionary(moves.filter { !$0.seen }.map { ($0.reminderId, $0) }, uniquingKeysWith: { _, last in last })
        conflictedIds = (try? store.conflictedReminderIds(endingAfter: Date())) ?? []
    }

    func currentSchedule() -> WorkSchedule {
        (try? store?.schedule()) ?? .standard
    }

    func markMovesSeen(_ id: String) {
        guard let store, unseenMoves[id] != nil else { return }
        try? store.markMovesSeen(reminderId: id)
        reload()
    }

    func saveSchedule(_ schedule: WorkSchedule) {
        guard let store, schedule != currentSchedule() else { return }
        let calendarsChanged = schedule.busyCalendarIds != currentSchedule().busyCalendarIds
        do {
            try store.setSchedule(schedule)
        } catch {
            showError(String(describing: error))
            return
        }
        // The app's store posts nothing for its own writes (onChange is empty): it reconciles directly, the CLI rereads the file.
        pendingScheduleCause = .settingsChanged
        if calendarsChanged {
            markBusyDirty()
        } else {
            requestReconcile()
        }
    }

    func setFixed(_ id: String, _ fixed: Bool) {
        perform {
            try $0.setFixed(id, fixed)
            return nil
        }
    }

    func setDuration(_ id: String, minutes: Int) {
        perform {
            try $0.setDuration(id, minutes: minutes)
            return nil
        }
    }

    func setDeadline(_ id: String, _ deadline: Date?) {
        perform {
            try $0.setDeadline(id, deadline)
            return nil
        }
    }

    func add(title: String, notes: String, dueAt: Date, durationMinutes: Int? = nil, fixed: Bool = false) {
        perform {
            let minutes = try durationMinutes ?? $0.schedule().defaultDurationMinutes
            let reminder = try $0.add(ReminderDraft(
                title: title, notes: notes, dueAt: dueAt, source: .human,
                durationMinutes: minutes, fixed: fixed, notBefore: fixed ? nil : dueAt
            ))
            self.selection = reminder.id
            self.pendingScheduleCause = .reminderAdded
            self.pendingNewReminderId = reminder.id
            return String(localized: "Added for \(Format.dueLabel(dueAt, now: Date()))")
        }
    }
}
