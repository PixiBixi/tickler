import Foundation

public enum ScheduleCause: Sendable {
    case reminderAdded, settingsChanged, calendar, routine
}

public struct ScheduleOutcome: Sendable {
    public var moves: [ScheduleMove]
    public var late: Set<String>
    public var unplaced: Set<String>
    public var conflicts: [ScheduleConflict]
    public var warning: String?

    public init(
        moves: [ScheduleMove] = [],
        late: Set<String> = [],
        unplaced: Set<String> = [],
        conflicts: [ScheduleConflict] = [],
        warning: String? = nil
    ) {
        self.moves = moves
        self.late = late
        self.unplaced = unplaced
        self.conflicts = conflicts
        self.warning = warning
    }
}

/// Reads the store, plans, and writes the placements. Shared by the CLI and the app.
public enum ScheduleRunner {
    private static let freshSeconds: TimeInterval = 3600
    private static let ignoredSeconds: TimeInterval = 24 * 3600

    /// The calendar copy as the planner may use it, by its age.
    struct BusyChoice {
        var busy: [DateInterval]
        /// Fresh enough to plan the whole day around.
        var trusted: Bool
        var warning: String?
    }

    public static func run(
        store: ReminderStore,
        now: Date,
        calendar: Calendar,
        cause: ScheduleCause,
        touched: String? = nil,
        touchedIsNew: Bool = false,
        freshBusy: Bool = false
    ) throws -> ScheduleOutcome {
        let input = try busyChoice(store: store, now: now, freshBusy: freshBusy)
        // A stale copy with nothing touched: no write is safe.
        guard let scope = input.trusted ? PlanScope.all : touched.map(PlanScope.only) else {
            return ScheduleOutcome(warning: input.warning)
        }
        let read = try store.list(ReminderFilter(due: .all, status: .open))
        let schedule = try store.schedule()
        let pending = try scope == .all && !store.isScheduleMigrated()
        // Only a full-scope run leaves or reuses a stamp; a touched reminder always replans.
        let stamping = scope == .all && !pending
        let inputs = PlanInputs(reminders: read, busy: input.busy, schedule: schedule, calendar: calendar)
        let fingerprint = try stamping && touched == nil ? inputs.fingerprint() : nil
        if let fingerprint, let stamp = try store.planStamp(), stamp.fingerprint == fingerprint, now < stamp.validUntil {
            let conflicts = SchedulePlanner.conflicts(reminders: read, busy: input.busy, schedule: schedule, now: now)
            return ScheduleOutcome(late: Set(stamp.late), conflicts: conflicts, warning: input.warning)
        }
        let plan = SchedulePlanner.plan(
            reminders: read,
            busy: input.busy,
            schedule: schedule,
            now: now,
            calendar: calendar,
            scope: scope,
            touched: touched,
            touchedIsNew: touchedIsNew
        )
        // The one-time repack moves reminders: only automatic mode may, the others just mark it done.
        let migrating = pending && schedule.mode == .auto
        let moves = try store.place(
            plan.placements,
            expecting: Dictionary(read.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            reason: {
                // An unplaced reminder only keeps its own time: not a move worth telling.
                plan.unplaced.contains($0.reminderId)
                    ? nil : reason(for: $0, touched: touched, migrating: migrating, cause: cause, calendar: calendar)
            },
            at: now
        )
        if pending {
            try store.markScheduleMigrated()
        }
        if stamping {
            try stamp(plan, inputs: inputs, store: store, now: now)
        }
        return ScheduleOutcome(
            moves: moves, late: plan.late, unplaced: plan.unplaced, conflicts: plan.conflicts, warning: input.warning
        )
    }

    /// Stamps the state the placements lead to. Replanning it before `stableUntil` gives the same plan with no move:
    /// each placed reminder keeps its slot while the bound `now + 15 min` has not passed it.
    private static func stamp(_ plan: SchedulePlan, inputs: PlanInputs, store: ReminderStore, now: Date) throws {
        let validUntil = min(plan.stableUntil, now.addingTimeInterval(PlanStamp.maxReuseSeconds))
        guard validUntil > now else { return }
        let byId = Dictionary(plan.placements.map { ($0.reminderId, $0) }, uniquingKeysWith: { first, _ in first })
        var after = inputs
        after.reminders = inputs.reminders.map { reminder in
            byId[reminder.id].map { ReminderStore.placed(reminder, by: $0, at: now) } ?? reminder
        }
        let fingerprint = try after.fingerprint()
        try store.setPlanStamp(PlanStamp(fingerprint: fingerprint, validUntil: validUntil, late: plan.late.sorted()))
    }

    static func busyChoice(store: ReminderStore, now: Date, freshBusy: Bool = false) throws -> BusyChoice {
        let age = try store.busySnapshotAt().map { now.timeIntervalSince($0) }
        if freshBusy || age.map({ $0 < freshSeconds }) == true {
            return try BusyChoice(busy: store.busy(), trusted: true, warning: nil)
        }
        if let age, age <= ignoredSeconds {
            let hours = Int(age / 3600)
            return try BusyChoice(
                busy: store.busy(),
                trusted: false,
                warning: "calendar copy is \(hours) h old, Tickler.app will correct the time"
            )
        }
        return BusyChoice(
            busy: [],
            trusted: false,
            warning: "no recent calendar copy, placed around other reminders only; Tickler.app will correct the time"
        )
    }

    /// Where a new reminder of `minutes` would land, not before `notBefore`. Writes nothing; nil when no slot exists.
    public static func slot(
        store: ReminderStore, now: Date, calendar: Calendar, minutes: Int, notBefore: Date
    ) throws -> (start: Date, warning: String?)? {
        let id = "slot"
        let choice = try busyChoice(store: store, now: now)
        let draft = Reminder(
            id: id, title: id, notes: "", dueAt: notBefore, originalDueAt: notBefore, rescheduleCount: 0, status: .open,
            source: .human, createdAt: now, updatedAt: now, durationMinutes: minutes, notBefore: notBefore
        )
        let plan = try SchedulePlanner.plan(
            reminders: store.list(ReminderFilter(due: .all, status: .open)) + [draft],
            busy: choice.busy,
            schedule: store.schedule(),
            now: now,
            calendar: calendar,
            scope: .only(id),
            touched: id,
            touchedIsNew: true
        )
        guard !plan.unplaced.contains(id) else { return nil }
        return (plan.placements.first { $0.reminderId == id }?.to ?? notBefore, choice.warning)
    }

    private static func reason(
        for placement: Placement,
        touched: String?,
        migrating: Bool,
        cause: ScheduleCause,
        calendar: Calendar
    ) -> MoveReason? {
        if placement.reminderId == touched {
            return nil
        }
        if migrating {
            return .migration
        }
        if placement.to < placement.from {
            return .slotFreed
        }
        if !calendar.isDate(placement.to, inSameDayAs: placement.from) {
            return .dayFull
        }
        switch cause {
        case .reminderAdded: return .reminderAdded
        case .settingsChanged: return .settingsChanged
        case .calendar: return .meeting
        case .routine: return .replanned
        }
    }
}
