import Foundation
import GRDB

extension ReminderStore {
    private static let scheduleKey = "workSchedule"
    static let busySnapshotKey = "busySnapshotAt"

    /// A missing row is the standard schedule.
    public func schedule() throws -> WorkSchedule {
        try database.pool.read { db in
            guard let json = try Self.setting(Self.scheduleKey, in: db) else { return .standard }
            return try JSONDecoder().decode(WorkSchedule.self, from: Data(json.utf8))
        }
    }

    /// Posts nothing: the caller notifies, as for other writes.
    public func setSchedule(_ schedule: WorkSchedule) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(decoding: encoder.encode(schedule), as: UTF8.self)
        try database.pool.write { db in try Self.setSetting(Self.scheduleKey, json, in: db) }
    }

    public func busySnapshotAt() throws -> Date? {
        try database.pool.read { db in
            try Self.setting(Self.busySnapshotKey, in: db).flatMap { ISO8601DateFormatter().date(from: $0) }
        }
    }

    func setBusySnapshotAt(_ date: Date) throws {
        let text = ISO8601DateFormatter().string(from: date)
        try database.pool.write { db in try Self.setSetting(Self.busySnapshotKey, text, in: db) }
    }

    static func setting(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
    }

    static func setSetting(_ key: String, _ value: String, in db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: [key, value])
    }
}

extension ReminderStore {
    private static let migratedKey = "scheduleMigrated"

    public func isScheduleMigrated() throws -> Bool {
        try database.pool.read { db in try Self.setting(Self.migratedKey, in: db) != nil }
    }

    func markScheduleMigrated() throws {
        try database.pool.write { db in try Self.setSetting(Self.migratedKey, "1", in: db) }
    }
}
