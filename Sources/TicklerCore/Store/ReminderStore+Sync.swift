import Foundation
import GRDB

/// Bookkeeping the app writes while syncing. It never posts a change: the app would reconcile its own writes forever.
public extension ReminderStore {
    /// Open reminders plus every reminder a calendar event still points at, as `CalendarPlanner.plan` expects.
    func syncCandidates() throws -> [Reminder] {
        try database.pool.read { db in
            let mapped = try String.fetchAll(db, sql: "SELECT reminderId FROM calendarEvent")
            return try Reminder
                .filter(Column("status") == Reminder.Status.open.rawValue || mapped.contains(Column("id")))
                .order(Column("dueAt"))
                .fetchAll(db)
        }
    }

    func calendarMappings() throws -> [CalendarMapping] {
        try database.pool.read { db in try CalendarMapping.fetchAll(db) }
    }

    /// One transaction per sync run rather than one per event (#25).
    func updateMappings(saving: [CalendarMapping], deleting reminderIds: [String]) throws {
        guard !saving.isEmpty || !reminderIds.isEmpty else { return }
        try database.pool.write { db in
            _ = try CalendarMapping.deleteAll(db, keys: reminderIds)
            for mapping in saving {
                try mapping.save(db)
            }
        }
    }
}
