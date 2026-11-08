import Foundation
import GRDB

/// The SQLite file shared by the CLI and the app. Either one may create it.
public final class TicklerDatabase: Sendable {
    public let pool: DatabasePool

    public init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        // The CLI and the app write concurrently: wait for the lock instead of failing.
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        pool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    /// `TICKLER_DB` overrides the default location, for tests and experiments.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["TICKLER_DB"], !override.isEmpty {
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tickler/tickler.sqlite").path
    }

    static var migrator: DatabaseMigrator {
        migrator(now: Date(), calendar: .current)
    }

    /// `now` and `calendar` only matter to the data migration of `v6-schedule`.
    static func migrator(now: Date, calendar: Calendar) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerBaseMigrations(&migrator)
        migrator.registerMigration("v6-schedule") { db in
            try db.create(table: "setting") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            try Self.migrateSchedule(db, now: now, calendar: calendar)
        }
        return migrator
    }

    private static func registerBaseMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.create(table: "reminder") { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("notes", .text).notNull().defaults(to: "")
                table.column("dueAt", .datetime).notNull().indexed()
                table.column("originalDueAt", .datetime).notNull()
                table.column("rescheduleCount", .integer).notNull().defaults(to: 0)
                table.column("status", .text).notNull().indexed()
                table.column("sessionId", .text)
                table.column("cwd", .text)
                table.column("source", .text).notNull()
                table.column("externalRef", .text).unique()
                table.column("notifiedAt", .datetime)
                table.column("doneAt", .datetime)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "link") { table in
                table.column("reminderId", .text).notNull().references("reminder", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("url", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("label", .text).notNull()
                table.primaryKey(["reminderId", "position"])
            }
            try db.create(table: "calendarEvent") { table in
                table.primaryKey("reminderId", .text).references("reminder", onDelete: .cascade)
                table.column("eventIdentifier", .text).notNull()
                table.column("calendarId", .text).notNull()
                table.column("syncedHash", .text).notNull()
            }
        }
        registerRunMigrations(&migrator)
    }

    private static func registerRunMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-resume-prompt") { db in
            try db.alter(table: "reminder") { table in
                table.add(column: "resumePrompt", .text)
            }
        }
        migrator.registerMigration("v3-trigger") { db in
            try db.alter(table: "reminder") { table in
                table.add(column: "trigger", .text)
                table.add(column: "firedAt", .datetime)
                table.add(column: "firedReason", .text)
            }
        }
        migrator.registerMigration("v4-auto-run") { db in
            try db.alter(table: "reminder") { table in
                table.add(column: "autoRun", .text)
            }
            try db.create(table: "run") { table in
                table.primaryKey("id", .text)
                table.column("reminderId", .text).notNull().indexed().references("reminder", onDelete: .cascade)
                table.column("forDueAt", .datetime).notNull()
                table.column("sessionId", .text)
                table.column("mode", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime)
                table.column("state", .text).notNull()
                table.column("verdict", .text)
                table.column("headline", .text)
                table.column("figures", .text).notNull().defaults(to: "[]")
                table.column("nextStep", .text)
                table.column("output", .text)
                table.column("error", .text)
                table.column("denials", .integer)
                table.column("costUsd", .double)
                table.column("durationMs", .integer)
            }
        }
        migrator.registerMigration("v5-fresh") { db in
            try db.alter(table: "reminder") { table in
                table.add(column: "fresh", .boolean).notNull().defaults(to: false)
            }
        }
    }

    /// Scheduling columns, busy copy, move log and conflict log, then the first classification of open rows.
    private static func migrateSchedule(_ db: Database, now: Date, calendar: Calendar) throws {
        try db.alter(table: "reminder") { table in
            table.add(column: "durationMinutes", .integer).notNull().defaults(to: 15)
            table.add(column: "fixed", .boolean).notNull().defaults(to: false)
            table.add(column: "notBefore", .datetime)
            table.add(column: "deadline", .datetime)
        }
        try db.create(table: "busyInterval") { table in
            table.column("start", .datetime).notNull()
            table.column("end", .datetime).notNull()
            table.primaryKey(["start", "end"])
        }
        try db.create(table: "scheduleMove") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("reminderId", .text).notNull().indexed().references("reminder", onDelete: .cascade)
            table.column("from", .datetime).notNull()
            table.column("to", .datetime).notNull()
            table.column("reason", .text).notNull()
            table.column("at", .datetime).notNull().indexed()
            table.column("seen", .boolean).notNull().defaults(to: false)
        }
        try db.create(table: "scheduleConflict") { table in
            table.column("reminderId", .text).notNull().references("reminder", onDelete: .cascade)
            table.column("start", .datetime).notNull()
            table.column("end", .datetime).notNull()
            table.column("at", .datetime).notNull()
            table.primaryKey(["reminderId", "start", "end"])
        }
        try db.execute(sql: "UPDATE reminder SET fixed = 1 WHERE status = 'open' AND (autoRun IS NOT NULL OR firedAt IS NOT NULL)")
        // No stored schedule exists yet: the standard start of day stands in.
        let start = WorkSchedule.standard.start.minutes
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, dueAt FROM reminder WHERE status = 'open' AND fixed = 0 AND dueAt > ?", arguments: [now]
        )
        for row in rows {
            let due: Date = row["dueAt"]
            let notBefore = calendar.date(byAdding: .minute, value: start, to: calendar.startOfDay(for: due)) ?? due
            try db.execute(sql: "UPDATE reminder SET notBefore = ? WHERE id = ?", arguments: [notBefore, row["id"] as String])
        }
    }
}
