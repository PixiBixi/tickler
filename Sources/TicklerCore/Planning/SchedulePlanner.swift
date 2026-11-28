import Foundation

public enum PlanScope: Sendable, Equatable {
    case all
    /// Place this reminder only; every other one stays at its current time.
    case only(String)
}

public struct SchedulePlan: Equatable, Sendable {
    public var placements: [Placement]
    public var late: Set<String>
    public var unplaced: Set<String>
    public var conflicts: [ScheduleConflict]
    /// Same inputs give the same plan before this instant: a planned reminder then reaches the freeze,
    /// or the horizon of one that found no slot moves to the next day.
    public var stableUntil: Date = .distantFuture

    public init(
        placements: [Placement] = [],
        late: Set<String> = [],
        unplaced: Set<String> = [],
        conflicts: [ScheduleConflict] = []
    ) {
        self.placements = placements
        self.late = late
        self.unplaced = unplaced
        self.conflicts = conflicts
    }
}

/// Pure placement of flexible reminders into the free time of the work schedule.
public enum SchedulePlanner {
    static let freezeSeconds: TimeInterval = 15 * 60
    static let gridSeconds: TimeInterval = 5 * 60
    static let horizonWorkingDays = 30
    /// Keeps `minutes * 60` far from overflow on a hand-edited row.
    static let maxMinutes = 100_000

    private struct Environment {
        let schedule: WorkSchedule
        let calendar: Calendar
        let time: WorkingTime
        let now: Date
        /// Busy, fixed and frozen time: what the lunch reservation ignores flexible reminders for.
        let fixedBlockers: [DateInterval]
    }

    private struct State {
        var blockers: BlockerIndex
        /// Each day walked, by its midnight, and the next one: computed once per plan.
        var days: [Date: WorkDay?] = [:]
        var nextDays: [Date: Date?] = [:]
    }

    /// A working day: its window, its midnight (the 5 minute grid origin) and its lunch gap.
    private struct WorkDay {
        let window: DateInterval
        let midnight: Date
        let lunch: DateInterval?

        /// The latest end among the blockers and the lunch gap overlapping `[start, end)`.
        func latestEnd(overlappingFrom start: Date, to end: Date, in index: BlockerIndex) -> Date? {
            let latest = index.latestEnd(overlappingFrom: start, to: end)
            guard let lunch, lunch.duration > 0, lunch.start < end, lunch.end > start else { return latest }
            return max(latest ?? lunch.end, lunch.end)
        }

        /// `roundedUp` without a calendar call. A date past this day is past the window too, so the fit fails either way.
        func roundedUp(_ date: Date) -> Date {
            let seconds = date.timeIntervalSince(midnight)
            return midnight.addingTimeInterval((seconds / gridSeconds).rounded(.up) * gridSeconds)
        }
    }

    private struct Split {
        var planned: [Reminder] = []
        var staying: [Reminder] = []
        var held: [Reminder] = []
    }

    public static func plan(
        reminders: [Reminder],
        busy: [DateInterval],
        schedule: WorkSchedule,
        now: Date,
        calendar: Calendar,
        scope: PlanScope = .all,
        touched: String? = nil,
        touchedIsNew: Bool = false
    ) -> SchedulePlan {
        let open = reminders.filter { $0.status == .open }
        let busy = busy.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        // Only a reminder created by this very command skips the freeze and the lead.
        let newId = touchedIsNew ? touched : nil
        let split = split(open, now: now, scope: scope, newId: newId, mode: schedule.mode)
        var result = SchedulePlan(conflicts: conflicts(of: watched(split, mode: schedule.mode), busy: busy, schedule: schedule, now: now))
        let time = WorkingTime(schedule: schedule, calendar: calendar)
        guard time.isUsable else {
            // Unusable settings: nothing can be placed, nothing is moved.
            result.unplaced = Set(split.planned.map(\.id))
            for reminder in split.planned {
                result.stableUntil = min(result.stableUntil, reminder.dueAt.addingTimeInterval(-freezeSeconds))
            }
            return result
        }
        let heldSpans = split.held.map { span($0, schedule: schedule) }
        let environment = Environment(
            schedule: schedule, calendar: calendar, time: time, now: now, fixedBlockers: (busy + heldSpans).sorted { $0.start < $1.start }
        )
        var state = State(blockers: BlockerIndex(busy + heldSpans + split.staying.map { span($0, schedule: schedule) }))
        for reminder in split.staying where isLate(reminder, start: reminder.dueAt) {
            result.late.insert(reminder.id)
        }
        for reminder in sorted(split.planned) {
            if schedule.mode == .off {
                placeUnchecked(reminder, environment: environment, into: &result)
                continue
            }
            place(reminder, isNew: reminder.id == newId, environment: environment, state: &state, into: &result)
        }
        return result
    }

    /// The conflicts a full-scope `plan` reports, without placing anything: a skipped run still sees new ones.
    static func conflicts(reminders: [Reminder], busy: [DateInterval], schedule: WorkSchedule, now: Date) -> [ScheduleConflict] {
        let open = reminders.filter { $0.status == .open }
        let busy = busy.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        let split = split(open, now: now, scope: .all, newId: nil, mode: schedule.mode)
        return conflicts(of: watched(split, mode: schedule.mode), busy: busy, schedule: schedule, now: now)
    }

    // MARK: Steps

    /// Outside auto nothing moves away from a meeting, so a pinned flexible reminder gets the in-app mark too.
    private static func watched(_ split: Split, mode: SchedulingMode) -> [Reminder] {
        mode == .auto ? split.held : split.held + split.staying
    }

    private static func split(_ open: [Reminder], now: Date, scope: PlanScope, newId: String?, mode: SchedulingMode) -> Split {
        var split = Split()
        for reminder in open {
            if reminder.holdsItsTime {
                split.held.append(reminder)
                continue
            }
            var onlyId: String?
            if case let .only(id) = scope {
                onlyId = id
            }
            let frozen = reminder.id != newId && reminder.dueAt < now.addingTimeInterval(freezeSeconds)
            // Outside automatic mode only the new reminder is ever placed.
            let pinned = (onlyId != nil && reminder.id != onlyId) || (mode != .auto && reminder.id != newId)
            if frozen || pinned {
                split.staying.append(reminder)
            } else {
                split.planned.append(reminder)
            }
        }
        return split
    }

    private static func sorted(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted { lhs, rhs in
            switch (lhs.deadline, rhs.deadline) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private static func place(
        _ reminder: Reminder,
        isNew: Bool,
        environment: Environment,
        state: inout State,
        into result: inout SchedulePlan
    ) {
        let minutes = minutes(of: reminder, schedule: environment.schedule)
        let lead = isNew ? 0 : freezeSeconds
        let bound = max(reminder.earliestStart, environment.now.addingTimeInterval(lead))
        guard let start = firstSlot(minutes: minutes, from: bound, environment: environment, state: &state) else {
            // Step 6: it keeps its own time (never earlier than the lead after now), and nothing else is placed over it.
            result.unplaced.insert(reminder.id)
            let floor = environment.now.addingTimeInterval(lead)
            let kept = reminder.dueAt >= floor ? reminder.dueAt : roundedUp(floor, calendar: environment.calendar)
            let horizonMoves = nextDay(after: environment.calendar.startOfDay(for: bound), calendar: environment.calendar, state: &state)
            result.stableUntil = min(
                result.stableUntil, kept.addingTimeInterval(-freezeSeconds),
                (horizonMoves ?? environment.now).addingTimeInterval(-freezeSeconds)
            )
            state.blockers.insert(DateInterval(start: kept, duration: TimeInterval(minutes * 60)))
            if kept != reminder.dueAt {
                result.placements.append(Placement(reminderId: reminder.id, from: reminder.dueAt, to: kept))
            }
            return
        }
        state.blockers.insert(DateInterval(start: start, duration: TimeInterval(minutes * 60)))
        result.stableUntil = min(result.stableUntil, start.addingTimeInterval(-freezeSeconds))
        if isLate(reminder, start: start) {
            result.late.insert(reminder.id)
        }
        if start != reminder.dueAt {
            result.placements.append(Placement(reminderId: reminder.id, from: reminder.dueAt, to: start))
        }
    }

    /// Off mode: the earliest start clamped into working time, ignoring meetings, lunch and other reminders.
    private static func placeUnchecked(_ reminder: Reminder, environment: Environment, into result: inout SchedulePlan) {
        var schedule = environment.schedule
        schedule.lunch = nil
        let bare = Environment(
            schedule: schedule,
            calendar: environment.calendar,
            time: environment.time,
            now: environment.now,
            fixedBlockers: []
        )
        var state = State(blockers: BlockerIndex())
        let minutes = minutes(of: reminder, schedule: schedule)
        let bound = max(reminder.earliestStart, environment.now)
        guard let start = firstSlot(minutes: minutes, from: bound, environment: bare, state: &state) else {
            result.unplaced.insert(reminder.id)
            result.stableUntil = min(result.stableUntil, environment.now)
            return
        }
        result.stableUntil = min(result.stableUntil, start.addingTimeInterval(-freezeSeconds))
        if isLate(reminder, start: start) {
            result.late.insert(reminder.id)
        }
        if start != reminder.dueAt {
            result.placements.append(Placement(reminderId: reminder.id, from: reminder.dueAt, to: start))
        }
    }

    private static func isLate(_ reminder: Reminder, start: Date) -> Bool {
        reminder.deadline.map { start > $0 } ?? false
    }

    private static func firstSlot(minutes: Int, from bound: Date, environment: Environment, state: inout State) -> Date? {
        let calendar = environment.calendar
        var day = calendar.startOfDay(for: bound)
        var workingDays = 0
        var calendarDays = 0
        while workingDays < horizonWorkingDays, calendarDays < horizonWorkingDays * WorkingTime.maxGapDays {
            if let workDay = workDay(on: day, environment: environment, state: &state) {
                workingDays += 1
                if let start = firstFit(minutes: minutes, on: workDay, from: bound, blockers: state.blockers) {
                    return start
                }
            }
            guard let next = nextDay(after: day, calendar: calendar, state: &state) else { return nil }
            day = next
            calendarDays += 1
        }
        return nil
    }

    private static func workDay(on day: Date, environment: Environment, state: inout State) -> WorkDay? {
        if let cached = state.days[day] {
            return cached
        }
        let workDay = environment.time.window(on: day).map { window in
            WorkDay(
                window: window,
                midnight: environment.calendar.startOfDay(for: window.start),
                lunch: lunchGap(in: window, environment: environment)
            )
        }
        state.days[day] = .some(workDay)
        return workDay
    }

    private static func nextDay(after day: Date, calendar: Calendar, state: inout State) -> Date? {
        if let cached = state.nextDays[day] {
            return cached
        }
        let next = calendar.date(byAdding: .day, value: 1, to: day)
        state.nextDays[day] = .some(next)
        return next
    }

    /// The earliest grid start from which `minutes` fit before the window ends, jumping past the latest blocker hit.
    private static func firstFit(minutes: Int, on day: WorkDay, from bound: Date, blockers: BlockerIndex) -> Date? {
        let length = TimeInterval(minutes * 60)
        var candidate = day.roundedUp(max(bound, day.window.start))
        while candidate.addingTimeInterval(length) <= day.window.end {
            guard let latest = day.latestEnd(overlappingFrom: candidate, to: candidate.addingTimeInterval(length), in: blockers) else {
                return candidate
            }
            candidate = day.roundedUp(latest)
        }
        return nil
    }

    /// The latest free gap of the lunch length inside the lunch range, from busy and fixed time only.
    private static func lunchGap(in window: DateInterval, environment: Environment) -> DateInterval? {
        guard let lunch = environment.schedule.lunch, lunch.minutes > 0,
              let from = environment.time.date(lunch.from, on: window.start),
              let to = environment.time.date(lunch.to, on: window.start) else { return nil }
        let rangeStart = max(from, window.start)
        let rangeEnd = min(to, window.end)
        guard rangeStart < rangeEnd else { return nil }
        let range = DateInterval(start: rangeStart, end: rangeEnd)
        let needed = TimeInterval(min(lunch.minutes, maxMinutes) * 60)
        var best: DateInterval?
        var cursor = range.start
        func consider(_ end: Date) {
            if end.timeIntervalSince(cursor) >= needed {
                best = DateInterval(start: end.addingTimeInterval(-needed), end: end)
            }
        }
        for blocker in environment.fixedBlockers
            where blocker.end > range.start && blocker.start < range.end
        {
            consider(min(blocker.start, range.end))
            cursor = max(cursor, blocker.end)
        }
        consider(range.end)
        return best
    }

    /// Only a future reminder the owner fixed: auto-run, fired and overdue ones cannot be moved by them.
    private static func conflicts(
        of held: [Reminder], busy: [DateInterval], schedule: WorkSchedule, now: Date
    ) -> [ScheduleConflict] {
        let owned = held.filter { ($0.fixed || schedule.mode != .auto) && $0.autoRun == nil && $0.firedAt == nil && $0.dueAt > now }
        let ordered = owned.sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
        var found: [ScheduleConflict] = []
        for reminder in ordered {
            let own = span(reminder, schedule: schedule)
            for interval in busy.sorted(by: { $0.start < $1.start }) where interval.start < own.end && interval.end > own.start {
                found.append(ScheduleConflict(reminderId: reminder.id, interval: interval))
            }
        }
        return found
    }

    // MARK: Helpers

    /// A non-positive duration (a hand-written row) falls back to the schedule default, then to 15.
    private static func minutes(of reminder: Reminder, schedule: WorkSchedule) -> Int {
        let own = reminder.durationMinutes > 0 ? reminder.durationMinutes : schedule.defaultDurationMinutes
        return min(own > 0 ? own : 15, maxMinutes)
    }

    private static func span(_ reminder: Reminder, schedule: WorkSchedule) -> DateInterval {
        DateInterval(start: reminder.dueAt, duration: TimeInterval(minutes(of: reminder, schedule: schedule) * 60))
    }

    private static func roundedUp(_ date: Date, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: date)
        let seconds = date.timeIntervalSince(midnight)
        return midnight.addingTimeInterval((seconds / gridSeconds).rounded(.up) * gridSeconds)
    }
}
