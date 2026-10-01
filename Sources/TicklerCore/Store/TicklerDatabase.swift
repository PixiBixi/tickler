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
        var migrator = DatabaseMigrator()
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
        migrator.registerMigration("v2-resume-prompt") { db in
            try db.alter(table: "reminder") { table in
                table.add(column: "resumePrompt", .text)
            }
        }
        return migrator
    }
}
