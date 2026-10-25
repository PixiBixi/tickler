import Foundation
import GRDB

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case autoRunNeedsPrompt
    case autoRunNeedsFolder

    public var description: String {
        switch self {
        case let .notFound(id): "no reminder with id \(id)"
        case .autoRunNeedsPrompt: "auto-run needs a resume prompt"
        case .autoRunNeedsFolder: "auto-run needs a session folder"
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

    /// Any status: a deleted import still counts as imported.
    public func find(externalRef: String) throws -> Reminder? {
        try database.pool.read { db in try Reminder.filter(Column("externalRef") == externalRef).fetchOne(db) }
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
                rescheduleCount: 0, status: .open, sessionId: draft.sessionId, cwd: draft.cwd,
                resumePrompt: Self.normalized(draft.resumePrompt), source: draft.source,
                externalRef: draft.externalRef, notifiedAt: nil, doneAt: nil, createdAt: stamp, updatedAt: stamp,
                trigger: draft.trigger?.rawValue, autoRun: draft.autoRun?.rawValue
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
    /// `resumePrompt`: nil leaves it, an empty string clears it.
    @discardableResult
    public func update(
        _ id: String,
        title: String? = nil,
        notes: String? = nil,
        dueAt: Date? = nil,
        resumePrompt: String? = nil
    ) throws -> Reminder {
        if let dueAt, try require(id).dueAt != dueAt {
            try reschedule(id, to: dueAt)
        }
        guard title != nil || notes != nil || resumePrompt != nil else { return try require(id) }
        return try mutate(id) { reminder, _ in
            if let resumePrompt {
                reminder.resumePrompt = Self.normalized(resumePrompt)
            }
            if let title {
                reminder.title = title
            }
            if let notes {
                reminder.notes = notes
            }
        } afterSave: { db, before, after in
            guard before.notes != after.notes else { return }
            let current = try ReminderLink.filter(Column("reminderId") == id).order(Column("position")).fetchAll(db)
            let kept = LinkExtractor.linksAfterNotesChange(
                reminderId: id, oldNotes: before.notes, newNotes: after.notes, current: current
            )
            try ReminderLink.filter(Column("reminderId") == id).deleteAll(db)
            for link in kept {
                try link.insert(db)
            }
        }
    }

    /// One line, no control or format characters, trimmed; nothing left means no prompt.
    /// It is typed into Claude Code, so a leading `/` or `!` (slash command, bash mode) gets a `Resume: ` prefix.
    static func normalized(_ prompt: String?) -> String? {
        let joined = (prompt ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
        let kept = joined.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
        let line = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.hasPrefix("/") || line.hasPrefix("!") ? "Resume: " + line : line
    }

    /// Soft delete: the row stays for the calendar sync to clean up its event.
    public func delete(_ id: String) throws {
        try mutate(id) { reminder, _ in reminder.status = .deleted }
    }

    /// Sets, replaces or (nil) removes the trigger. A new trigger forgets the previous firing.
    @discardableResult
    public func setTrigger(_ id: String, _ trigger: Trigger?) throws -> Reminder {
        try mutate(id) { reminder, _ in
            reminder.trigger = trigger?.rawValue
            if trigger != nil {
                reminder.firedAt = nil
                reminder.firedReason = nil
            }
        }
    }

    /// Sets or (nil) removes the background run. A mode needs a resume prompt and a session folder to run in.
    @discardableResult
    public func setAutoRun(_ id: String, _ mode: AutoRunMode?) throws -> Reminder {
        if mode != nil {
            let current = try require(id)
            guard current.resumePrompt != nil else { throw StoreError.autoRunNeedsPrompt }
            guard let cwd = current.cwd, !cwd.isEmpty else { throw StoreError.autoRunNeedsFolder }
        }
        return try mutate(id) { reminder, _ in reminder.autoRun = mode?.rawValue }
    }

    /// Makes a waiting reminder due at `date`. Only an open reminder still waiting for `trigger` changes, so a second firing
    /// or a trigger replaced meanwhile is a no-op.
    /// Not a reschedule: `rescheduleCount` and `originalDueAt` stay.
    @discardableResult
    public func fire(_ id: String, expected trigger: Trigger, reason: String, at date: Date) throws -> Bool {
        let stamp = now()
        let changed = try database.pool.write { db in
            try Reminder
                .filter(Column("id") == id && Column("status") == Reminder.Status.open.rawValue && Column("trigger") == trigger.rawValue)
                .updateAll(
                    db,
                    Column("dueAt").set(to: date),
                    Column("notifiedAt").set(to: nil),
                    Column("trigger").set(to: nil),
                    Column("firedAt").set(to: date),
                    Column("firedReason").set(to: reason),
                    Column("updatedAt").set(to: stamp)
                )
        }
        if changed > 0 {
            onChange()
        }
        return changed > 0
    }

    /// Records that these reminders were notified, as read when the decision was made: one rescheduled, snoozed, fired
    /// or closed since keeps `notifiedAt` empty, so its new time still gets a notification and a catch-up.
    public func markNotified(_ reminders: [Reminder], at date: Date) throws {
        guard !reminders.isEmpty else { return }
        try database.pool.write { db in
            for reminder in reminders {
                _ = try Reminder
                    .filter(
                        Column("id") == reminder.id && Column("dueAt") == reminder.dueAt
                            && Column("status") == Reminder.Status.open.rawValue
                    )
                    .updateAll(db, Column("notifiedAt").set(to: date))
            }
        }
    }

    // MARK: Runs

    public func runs(for id: String) throws -> [AutoRun] {
        try database.pool.read { db in
            try AutoRun.filter(Column("reminderId") == id).order(Column("startedAt").desc, Column("rowid").desc).fetchAll(db)
        }
    }

    public func lastRuns(for ids: [String]) throws -> [String: AutoRun] {
        let all = try database.pool.read { db in
            try AutoRun.filter(ids.contains(Column("reminderId"))).order(Column("startedAt").desc, Column("rowid").desc).fetchAll(db)
        }
        return Dictionary(all.map { ($0.reminderId, $0) }, uniquingKeysWith: { newest, _ in newest })
    }

    /// Opens a run for the reminder as it is now; nil when one is already running or the reminder is gone.
    public func startRun(_ reminderId: String, at date: Date) throws -> AutoRun? {
        let run = try database.pool.write { db -> AutoRun? in
            guard let reminder = try Reminder.fetchOne(db, key: reminderId) else { throw StoreError.notFound(reminderId) }
            let running = try AutoRun
                .filter(Column("reminderId") == reminderId && Column("state") == AutoRun.State.running.rawValue)
                .fetchCount(db)
            guard running == 0 else { return nil }
            let run = try AutoRun(
                id: Self.newRunId(db), reminderId: reminderId, forDueAt: reminder.dueAt, sessionId: reminder.sessionId,
                mode: reminder.autoRunMode ?? .read, startedAt: date, state: .running
            )
            try run.insert(db)
            return run
        }
        if run != nil {
            onChange()
        }
        return run
    }

    /// Records a due run that did not start (Mac asleep, session busy...), so it is not retried.
    @discardableResult
    public func recordSkipped(_ reminderId: String, reason: String, at date: Date) throws -> AutoRun {
        let run = try database.pool.write { db in
            guard let reminder = try Reminder.fetchOne(db, key: reminderId) else { throw StoreError.notFound(reminderId) }
            let run = try AutoRun(
                id: Self.newRunId(db), reminderId: reminderId, forDueAt: reminder.dueAt, sessionId: reminder.sessionId,
                mode: reminder.autoRunMode ?? .read, startedAt: date, endedAt: date, state: .skipped, error: reason
            )
            try run.insert(db)
            return run
        }
        onChange()
        return run
    }

    /// Stores the outcome of a running run; false when it already ended. A session id the reminder lacked is kept.
    @discardableResult
    public func finishRun(_ runId: String, _ result: RunResult, at date: Date) throws -> Bool {
        let state: AutoRun.State = switch result.state {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
        let figures = try String(decoding: JSONEncoder().encode(result.figures), as: UTF8.self)
        let changed = try database.pool.write { db -> Bool in
            let updated = try AutoRun
                .filter(Column("id") == runId && Column("state") == AutoRun.State.running.rawValue)
                .updateAll(
                    db,
                    Column("endedAt").set(to: date),
                    Column("state").set(to: state.rawValue),
                    Column("verdict").set(to: result.verdict?.rawValue),
                    Column("headline").set(to: result.headline),
                    Column("figures").set(to: figures),
                    Column("nextStep").set(to: result.nextStep),
                    Column("output").set(to: result.output),
                    Column("error").set(to: result.error),
                    Column("denials").set(to: result.denials),
                    Column("costUsd").set(to: result.costUsd),
                    Column("durationMs").set(to: result.durationMs)
                )
            guard updated > 0 else { return false }
            if let sessionId = result.sessionId, let run = try AutoRun.fetchOne(db, key: runId) {
                _ = try Reminder
                    .filter(Column("id") == run.reminderId && Column("sessionId") == nil)
                    .updateAll(db, Column("sessionId").set(to: sessionId))
            }
            return true
        }
        if changed {
            onChange()
        }
        return changed
    }

    /// Marks every run left `running` (the app quit or crashed) as failed; returns how many.
    @discardableResult
    public func interruptRunning(at date: Date) throws -> Int {
        let count = try database.pool.write { db in
            try AutoRun
                .filter(Column("state") == AutoRun.State.running.rawValue)
                .updateAll(
                    db,
                    Column("state").set(to: AutoRun.State.failed.rawValue),
                    Column("error").set(to: "Interrupted"),
                    Column("endedAt").set(to: date)
                )
        }
        if count > 0 {
            onChange()
        }
        return count
    }

    private static func newRunId(_ db: Database) throws -> String {
        var id = ReminderID.generate()
        while try AutoRun.exists(db, key: id) {
            id = ReminderID.generate()
        }
        return id
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
