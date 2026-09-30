import Foundation
import GRDB

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case let .notFound(id): "no reminder with id \(id)"
        }
    }
}

/// Every read and write of reminders goes through here, from the CLI and from the app.
public final class ReminderStore: Sendable {
    public let database: TicklerDatabase
    let calendar: Calendar
    let now: @Sendable () -> Date
    let onChange: @Sendable () -> Void

    public init(
        database: TicklerDatabase,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping @Sendable () -> Void = { ChangeNotifier.post() }
    ) {
        self.database = database
        self.calendar = calendar
        self.now = now
        self.onChange = onChange
    }

    // MARK: Reads

    public func get(_ id: String) throws -> Reminder? {
        try database.pool.read { db in try Reminder.fetchOne(db, key: id) }
    }

    public func require(_ id: String) throws -> Reminder {
        guard let reminder = try get(id) else { throw StoreError.notFound(id) }
        return reminder
    }

    public func links(for id: String) throws -> [ReminderLink] {
        try database.pool.read { db in
            try ReminderLink.filter(Column("reminderId") == id).order(Column("position")).fetchAll(db)
        }
    }

    public func links(for ids: [String]) throws -> [String: [ReminderLink]] {
        let all = try database.pool.read { db in
            try ReminderLink.filter(ids.contains(Column("reminderId"))).order(Column("position")).fetchAll(db)
        }
        return Dictionary(grouping: all, by: \.reminderId)
    }

    public func list(_ filter: ReminderFilter) throws -> [Reminder] {
        let current = now()
        var request = Reminder.filter(Column("status") == filter.status.rawValue)
        switch filter.due {
        case .all:
            break
        case .overdue:
            request = request.filter(Column("dueAt") < current)
        case .today:
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current))!
            request = request.filter(Column("dueAt") < startOfTomorrow)
        case .week:
            request = request.filter(Column("dueAt") < current.addingTimeInterval(7 * 86400))
        }
        let order = filter.status == .done ? Column("doneAt").desc : Column("dueAt").asc
        let reminders = try database.pool.read { db in try request.order(order, Column("createdAt")).fetchAll(db) }
        guard let project = filter.project else { return reminders }
        return reminders.filter { $0.project == project }
    }

    // MARK: Writes

    @discardableResult
    public func add(_ draft: ReminderDraft) throws -> Reminder {
        let stamp = now()
        let reminder = try database.pool.write { db in
            var id = ReminderID.generate()
            while try Reminder.exists(db, key: id) {
                id = ReminderID.generate()
            }
            let reminder = Reminder(
                id: id, title: draft.title, notes: draft.notes, dueAt: draft.dueAt, originalDueAt: draft.dueAt,
                rescheduleCount: 0, status: .open, sessionId: draft.sessionId, cwd: draft.cwd, source: draft.source,
                externalRef: draft.externalRef, notifiedAt: nil, doneAt: nil, createdAt: stamp, updatedAt: stamp
            )
            try reminder.insert(db)
            for link in LinkExtractor.links(reminderId: id, notes: draft.notes, explicit: draft.links) {
                try link.insert(db)
            }
            return reminder
        }
        onChange()
        return reminder
    }

    @discardableResult
    public func markDone(_ id: String) throws -> Reminder {
        try mutate(id) { reminder, stamp in
            reminder.status = .done
            reminder.doneAt = stamp
        }
    }

    /// Moves the due date. Clears `notifiedAt` so the new time gets its own notification.
    @discardableResult
    public func reschedule(_ id: String, to dueAt: Date) throws -> Reminder {
        try mutate(id) { reminder, _ in
            reminder.dueAt = dueAt
            reminder.rescheduleCount += 1
            reminder.notifiedAt = nil
            if reminder.status == .done {
                reminder.status = .open; reminder.doneAt = nil
            }
        }
    }

    /// Edits title and notes; a changed date goes through `reschedule`. Notes rebuild the links, explicit ones stay.
    @discardableResult
    public func update(_ id: String, title: String? = nil, notes: String? = nil, dueAt: Date? = nil) throws -> Reminder {
        if let dueAt, try require(id).dueAt != dueAt {
            try reschedule(id, to: dueAt)
        }
        guard title != nil || notes != nil else { return try require(id) }
        return try mutate(id) { reminder, _ in
            if let title {
                reminder.title = title
            }
            if let notes {
                reminder.notes = notes
            }
        } afterSave: { db, before, after in
            guard before.notes != after.notes else { return }
            let fromOldNotes = Set(LinkExtractor.extract(from: before.notes).map(\.absoluteString))
            let explicit = try ReminderLink.filter(Column("reminderId") == id).order(Column("position")).fetchAll(db)
                .map(\.url).filter { !fromOldNotes.contains($0) }
            try ReminderLink.filter(Column("reminderId") == id).deleteAll(db)
            for link in LinkExtractor.links(reminderId: id, notes: after.notes, explicit: explicit) {
                try link.insert(db)
            }
        }
    }

    /// Soft delete: the row stays for the calendar sync to clean up its event.
    public func delete(_ id: String) throws {
        try mutate(id) { reminder, _ in reminder.status = .deleted }
    }

    public func markNotified(_ ids: [String], at date: Date) throws {
        guard !ids.isEmpty else { return }
        try database.pool.write { db in
            _ = try Reminder.filter(ids.contains(Column("id"))).updateAll(db, Column("notifiedAt").set(to: date))
        }
    }

    @discardableResult
    private func mutate(
        _ id: String,
        _ change: (inout Reminder, Date) -> Void,
        afterSave: ((Database, Reminder, Reminder) throws -> Void)? = nil
    ) throws -> Reminder {
        let stamp = now()
        let updated = try database.pool.write { db in
            guard var reminder = try Reminder.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            let before = reminder
            change(&reminder, stamp)
            reminder.updatedAt = stamp
            try reminder.update(db)
            try afterSave?(db, before, reminder)
            return reminder
        }
        onChange()
        return updated
    }
}
