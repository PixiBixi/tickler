import Foundation
import GRDB

public extension ReminderStore {
    /// One transaction. A row whose `dueAt` is not `from`, or that is no longer open, is skipped.
    /// `reason` nil writes the placement without a move row. `rescheduleCount` is never touched.
    /// `expecting` is the reminders the planner read: a row whose planning fields changed since is skipped.
    @discardableResult
    func place(
        _ placements: [Placement],
        expecting: [String: Reminder] = [:],
        reason: (Placement) -> MoveReason?,
        at date: Date
    ) throws -> [ScheduleMove] {
        let (moves, wrote) = try database.pool.write { db in
            var inserted: [ScheduleMove] = []
            var wrote = false
            for placement in placements {
                guard var reminder = try Reminder.fetchOne(db, key: placement.reminderId),
                      reminder.status == .open, reminder.dueAt == placement.from,
                      expecting[placement.reminderId].map({ Self.sameDecision($0, reminder) }) ?? true else { continue }
                // A row from an older CLI has no anchor: keep its original time so it cannot drift later.
                if reminder.notBefore == nil {
                    reminder.notBefore = placement.from
                }
                reminder.dueAt = placement.to
                reminder.notifiedAt = nil
                reminder.updatedAt = date
                try reminder.update(db)
                wrote = true
                guard let why = reason(placement) else { continue }
                let move = ScheduleMove(reminderId: placement.reminderId, from: placement.from, to: placement.to, reason: why, at: date)
                try inserted.append(move.inserted(db))
            }
            return (inserted, wrote)
        }
        if wrote {
            onChange()
        }
        return moves
    }

    private static func sameDecision(_ read: Reminder, _ current: Reminder) -> Bool {
        read.dueAt == current.dueAt && read.fixed == current.fixed && read.autoRun == current.autoRun
            && read.firedAt == current.firedAt && read.notBefore == current.notBefore
            && read.durationMinutes == current.durationMinutes && read.deadline == current.deadline
    }

    /// Replaces the whole busy copy and stamps its age, in one transaction.
    func replaceBusy(_ intervals: [DateInterval], at date: Date) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM busyInterval")
            for interval in Set(intervals) {
                try db.execute(
                    sql: #"INSERT INTO busyInterval ("start", "end") VALUES (?, ?)"#,
                    arguments: [interval.start, interval.end]
                )
            }
            try Self.setSetting(Self.busySnapshotKey, ISO8601DateFormatter().string(from: date), in: db)
        }
    }

    func busy() throws -> [DateInterval] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: #"SELECT "start", "end" FROM busyInterval ORDER BY "start", "end""#).map { row in
                DateInterval(start: row["start"], end: row["end"])
            }
        }
    }

    func moves(since: Date, includeMigration: Bool = false) throws -> [ScheduleMove] {
        try database.pool.read { db in
            var request = ScheduleMove.filter(Column("at") >= since)
            if !includeMigration {
                request = request.filter(Column("reason") != MoveReason.migration.rawValue)
            }
            return try request.order(Column("at"), Column("id")).fetchAll(db)
        }
    }

    func markMovesSeen(reminderId: String) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE scheduleMove SET seen = 1 WHERE reminderId = ?", arguments: [reminderId])
        }
        onChange()
    }

    @discardableResult
    func setFixed(_ id: String, _ fixed: Bool) throws -> Reminder {
        let current = try require(id)
        if !fixed {
            if current.autoRun != nil {
                throw StoreError.invalid("fixed by auto-run")
            }
            if current.firedAt != nil {
                throw StoreError.invalid("fixed by its fired trigger")
            }
        }
        return try mutateSchedule(id) { $0.fixed = fixed }
    }

    @discardableResult
    func setDuration(_ id: String, minutes: Int) throws -> Reminder {
        guard minutes > 0 else { throw StoreError.invalid("duration must be positive") }
        return try mutateSchedule(id) { $0.durationMinutes = minutes }
    }

    @discardableResult
    func setDeadline(_ id: String, _ deadline: Date?) throws -> Reminder {
        try mutateSchedule(id) { $0.deadline = deadline }
    }

    /// Returns only the conflicts never recorded before (key: reminder, start, end).
    func recordConflicts(_ conflicts: [ScheduleConflict], at date: Date) throws -> [ScheduleConflict] {
        try database.pool.write { db in
            try conflicts.filter { conflict in
                let before = db.totalChangesCount
                try db.execute(
                    sql: #"INSERT OR IGNORE INTO scheduleConflict (reminderId, "start", "end", at) VALUES (?, ?, ?, ?)"#,
                    arguments: [conflict.reminderId, conflict.interval.start, conflict.interval.end, date]
                )
                return db.totalChangesCount > before
            }
        }
    }

    /// Ids of reminders with a recorded conflict whose interval ends after `date`.
    func conflictedReminderIds(endingAfter date: Date) throws -> Set<String> {
        try database.pool.read { db in
            try Set(String.fetchAll(db, sql: #"SELECT DISTINCT reminderId FROM scheduleConflict WHERE "end" > ?"#, arguments: [date]))
        }
    }

    private func mutateSchedule(_ id: String, _ change: (inout Reminder) -> Void) throws -> Reminder {
        let stamp = now()
        let updated = try database.pool.write { db in
            guard var reminder = try Reminder.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            change(&reminder)
            reminder.updatedAt = stamp
            try reminder.update(db)
            return reminder
        }
        onChange()
        return updated
    }
}
