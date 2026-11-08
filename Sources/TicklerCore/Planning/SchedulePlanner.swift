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
        var blockers: [DateInterval]
        /// The lunch gap of each day, by the day's window start; computed once per plan.
        var lunch: [Date: DateInterval?] = [:]
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
        // Outside auto nothing moves away from a meeting, so a pinned flexible reminder gets the in-app mark too.
        let watched = schedule.mode == .auto ? split.held : split.held + split.staying
        var result = SchedulePlan(conflicts: conflicts(of: watched, busy: busy, schedule: schedule, now: now))
        let time = WorkingTime(schedule: schedule, calendar: calendar)
        guard time.isUsable else {
            // Unusable settings: nothing can be placed, nothing is moved.
            result.unplaced = Set(split.planned.map(\.id))
            return result
        }
        let heldSpans = split.held.map { span($0, schedule: schedule) }
        let environment = Environment(
            schedule: schedule, calendar: calendar, time: time, now: now, fixedBlockers: (busy + heldSpans).sorted { $0.start < $1.start }
        )
        var state = State(blockers: busy + heldSpans + split.staying.map { span($0, schedule: schedule) })
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

    // MARK: Steps

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
            state.blockers.append(DateInterval(start: kept, duration: TimeInterval(minutes * 60)))
            if kept != reminder.dueAt {
                result.placements.append(Placement(reminderId: reminder.id, from: reminder.dueAt, to: kept))
            }
            return
        }
        state.blockers.append(DateInterval(start: start, duration: TimeInterval(minutes * 60)))
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
        var state = State(blockers: [])
        let minutes = minutes(of: reminder, schedule: schedule)
        let bound = max(reminder.earliestStart, environment.now)
        guard let start = firstSlot(minutes: minutes, from: bound, environment: bare, state: &state) else {
            result.unplaced.insert(reminder.id)
            return
        }
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
            if let window = environment.time.window(on: day) {
                workingDays += 1
                var dayBlockers = state.blockers
                if state.lunch[window.start] == nil {
                    state.lunch[window.start] = .some(lunchGap(in: window, environment: environment))
                }
                if let lunch = state.lunch[window.start].flatMap(\.self) {
                    dayBlockers.append(lunch)
                }
                if let start = firstFit(minutes: minutes, in: window, from: bound, blockers: dayBlockers, calendar: calendar) {
                    return start
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            calendarDays += 1
        }
        return nil
    }

    private static func firstFit(
        minutes: Int,
        in window: DateInterval,
        from bound: Date,
        blockers: [DateInterval],
        calendar: Calendar
    ) -> Date? {
        let length = TimeInterval(minutes * 60)
        var candidate = roundedUp(max(bound, window.start), calendar: calendar)
        while candidate.addingTimeInterval(length) <= window.end {
            let end = candidate.addingTimeInterval(length)
            let hits = blockers.filter { $0.duration > 0 && $0.start < end && $0.end > candidate }
            guard let latest = hits.map(\.end).max() else { return candidate }
            candidate = roundedUp(latest, calendar: calendar)
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
