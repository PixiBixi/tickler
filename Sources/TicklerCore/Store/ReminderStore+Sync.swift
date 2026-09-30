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

    func saveMapping(_ mapping: CalendarMapping) throws {
        try database.pool.write { db in try mapping.save(db) }
    }

    func deleteMapping(reminderId: String) throws {
        _ = try database.pool.write { db in try CalendarMapping.deleteOne(db, key: reminderId) }
    }
}
