import Foundation
import Testing
@testable import TicklerCore

private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Fixture.calendar
    formatter.timeZone = Fixture.calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private func text(_ date: Date) -> String {
    formatter.dateFormat = Fixture.calendar.isDate(date, inSameDayAs: Fixture.now) ? "HH:mm" : "EEE HH:mm"
    return formatter.string(from: date)
}

private func make(_ title: String, due: String, created: Int) -> Reminder {
    let date = Fixture.date(due)
    return Reminder(
        id: title, title: title, notes: "", dueAt: date, originalDueAt: date, rescheduleCount: 0, status: .open,
        sessionId: nil, cwd: nil, source: .claude, externalRef: nil, notifiedAt: nil, doneAt: nil,
        createdAt: Fixture.now.addingTimeInterval(TimeInterval(created)), updatedAt: Fixture.now
    )
}

private func flex(
    _ title: String,
    notBefore: String = "2026-10-01 10:45",
    due: String? = nil,
    minutes: Int = 15,
    deadline: String? = nil,
    created: Int = 0
) -> Reminder {
    var reminder = make(title, due: due ?? "2026-10-01 17:00", created: created)
    reminder.durationMinutes = minutes
    reminder.notBefore = Fixture.date(notBefore)
    reminder.deadline = deadline.map(Fixture.date)
    return reminder
}

private func fixed(_ title: String, at due: String, minutes: Int = 15) -> Reminder {
    var reminder = make(title, due: due, created: 0)
    reminder.durationMinutes = minutes
    reminder.fixed = true
    return reminder
}

private func busy(_ from: String, _ to: String) -> DateInterval {
    DateInterval(start: Fixture.date(from), end: Fixture.date(to))
}

private func run(
    _ reminders: [Reminder],
    busy: [DateInterval] = [],
    schedule: WorkSchedule = .standard,
    now: Date = Fixture.now,
    scope: PlanScope = .all,
    touched: String? = nil,
    isNew: Bool = false
) -> SchedulePlan {
    SchedulePlanner.plan(
        reminders: reminders, busy: busy, schedule: schedule, now: now, calendar: Fixture.calendar, scope: scope, touched: touched,
        touchedIsNew: isNew
    )
}

/// Title to start, after the plan is applied.
private func starts(_ plan: SchedulePlan, _ reminders: [Reminder]) -> [String: String] {
    let moved = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.reminderId, $0.to) })
    return Dictionary(uniqueKeysWithValues: reminders.map { ($0.title, text(moved[$0.id] ?? $0.dueAt)) })
}

private func applied(_ plan: SchedulePlan, to reminders: [Reminder]) -> [Reminder] {
    let moved = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.reminderId, $0.to) })
    return reminders.map { reminder in
        var copy = reminder
        copy.dueAt = moved[reminder.id] ?? reminder.dueAt
        return copy
    }
}

struct SchedulePlannerTests {
    @Test func packsBackToBack() {
        let items = [flex("a", created: 1), flex("b", created: 2), flex("c", created: 3)]
        #expect(starts(run(items), items) == ["a": "11:00", "b": "11:15", "c": "11:30"])
    }

    @Test func touchedStartsNow() {
        let items = [flex("a", due: "2026-10-01 14:00")]
        #expect(starts(run(items, touched: "a", isNew: true), items) == ["a": "10:45"])
    }

    @Test func avoidsBusy() {
        let items = [flex("a", created: 1), flex("b", created: 2), flex("c", created: 3)]
        let plan = run(items, busy: [busy("2026-10-01 11:00", "2026-10-01 11:30")])
        #expect(starts(plan, items) == ["a": "11:30", "b": "11:45", "c": "12:00"])
    }

    @Test func fixedBlocks() {
        let items = [fixed("meet", at: "2026-10-01 11:00", minutes: 30), flex("a")]
        let plan = run(items)
        #expect(starts(plan, items)["a"] == "11:30")
        #expect(!plan.placements.contains { $0.reminderId == "meet" })
    }

    @Test func respectsNotBefore() {
        let items = [flex("a", notBefore: "2026-10-05 08:00")]
        #expect(starts(run(items), items) == ["a": "Mon 09:30"])
    }

    @Test func overflowsToNextWorkingDay() {
        let now = Fixture.date("2026-10-02 19:20")
        let items = [flex("a", notBefore: "2026-10-02 19:20", due: "2026-10-02 19:40")]
        #expect(starts(run(items, now: now), items) == ["a": "Mon 09:30"])
    }

    @Test func longTaskSkipsToRoomyDay() {
        var gaps: [DateInterval] = []
        for hour in 11 ..< 19 {
            gaps.append(busy("2026-10-01 \(hour):00", "2026-10-01 \(hour):30"))
        }
        gaps.append(busy("2026-10-01 19:00", "2026-10-01 19:30"))
        let items = [flex("long", minutes: 120)]
        #expect(starts(run(items, busy: gaps), items) == ["long": "Fri 09:30"])
    }

    @Test func frozenStays() {
        let items = [flex("soon", notBefore: "2026-10-01 10:00", due: "2026-10-01 10:55"), flex("a", created: 1)]
        let plan = run(items)
        #expect(!plan.placements.contains { $0.reminderId == "soon" })
        #expect(starts(plan, items)["a"] == "11:10")
    }

    @Test func pullsEarlierNotWithinFreeze() {
        let items = [flex("a", notBefore: "2026-10-01 10:00", due: "2026-10-01 15:00")]
        #expect(starts(run(items), items) == ["a": "11:00"])
    }

    @Test func neverBeforeNotBefore() {
        let items = [flex("a", notBefore: "2026-10-01 16:00", due: "2026-10-01 17:00")]
        #expect(starts(run(items), items) == ["a": "16:00"])
    }

    @Test func deadlineBeatsAge() {
        let items = [flex("old", created: 1), flex("new", deadline: "2026-10-01 12:00", created: 2)]
        #expect(starts(run(items), items) == ["new": "11:00", "old": "11:15"])
    }

    @Test func olderKeepsPlace() {
        let items = [flex("old", due: "2026-10-01 11:00", created: 1), flex("new", created: 2)]
        let plan = run(items)
        #expect(starts(plan, items) == ["old": "11:00", "new": "11:15"])
        #expect(!plan.placements.contains { $0.reminderId == "old" })
    }

    @Test func lateWhenNoRoomBeforeDeadline() {
        let items = [flex("a", deadline: "2026-10-01 18:00")]
        let plan = run(items, busy: [busy("2026-10-01 11:00", "2026-10-01 19:30")])
        #expect(starts(plan, items) == ["a": "Fri 09:30"])
        #expect(plan.late.contains("a"))
    }

    @Test func lunchReserved() {
        var schedule = WorkSchedule.standard
        schedule.lunch = Lunch(minutes: 45, from: TimeOfDay(minutes: 12 * 60), to: TimeOfDay(minutes: 14 * 60))
        let items = [flex("a", notBefore: "2026-10-01 12:00", minutes: 60)]
        let plan = run(items, busy: [busy("2026-10-01 13:30", "2026-10-01 14:00")], schedule: schedule)
        #expect(starts(plan, items) == ["a": "14:00"])
    }

    @Test func busyClippedToWindow() {
        let items = [flex("a", notBefore: "2026-10-01 11:00")]
        let plan = run(items, busy: [busy("2026-09-30 22:00", "2026-10-01 10:00")])
        #expect(starts(plan, items) == ["a": "11:00"])
    }

    @Test func dstDayKeepsWallClock() {
        let schedule = WorkSchedule(
            workingDays: Set(1 ... 7), start: TimeOfDay(minutes: 570), end: TimeOfDay(minutes: 1170), defaultDurationMinutes: 15
        )
        let now = Fixture.date("2026-10-25 08:00")
        let items = [flex("a", notBefore: "2026-10-25 08:00", due: "2026-10-25 17:00")]
        let plan = run(items, schedule: schedule, now: now)
        #expect(plan.placements.first?.to == Fixture.date("2026-10-25 09:30"))
        let window = WorkingTime(schedule: schedule, calendar: Fixture.calendar).window(on: now)
        #expect(window?.duration == TimeInterval(600 * 60))
    }

    @Test func noWorkingDayLeavesRemindersUnplaced() {
        var schedule = WorkSchedule.standard
        schedule.workingDays = []
        let items = [flex("a")]
        let plan = run(items, schedule: schedule)
        #expect(plan.unplaced == ["a"])
        #expect(plan.placements.isEmpty)
    }

    @Test func invertedHoursLeaveRemindersUnplaced() {
        var schedule = WorkSchedule.standard
        schedule.end = schedule.start
        #expect(run([flex("a")], schedule: schedule).unplaced == ["a"])
    }

    @Test func nonPositiveDurationUsesTheDefault() {
        let items = [flex("a", minutes: 0), flex("b", created: 1)]
        #expect(starts(run(items), items) == ["a": "11:00", "b": "11:15"])
    }

    @Test func onlyScopeMovesNothingElse() {
        let items = [flex("other", notBefore: "2026-10-01 10:00", due: "2026-10-01 16:00", created: 1), flex("new", created: 2)]
        let plan = run(items, scope: .only("new"), touched: "new", isNew: true)
        #expect(starts(plan, items) == ["other": "16:00", "new": "10:45"])
    }

    @Test func reportsFixedConflicts() {
        let items = [fixed("deploy", at: "2026-10-01 14:00", minutes: 30)]
        let interval = busy("2026-10-01 14:15", "2026-10-01 15:00")
        let plan = run(items, busy: [interval])
        #expect(plan.conflicts == [ScheduleConflict(reminderId: "deploy", interval: interval)])
    }

    @Test func lunchOutsideHoursDoesNotCrash() {
        var schedule = WorkSchedule.standard
        schedule.start = TimeOfDay(minutes: 15 * 60)
        schedule.end = TimeOfDay(minutes: 22 * 60)
        schedule.lunch = Lunch(minutes: 45, from: TimeOfDay(minutes: 12 * 60), to: TimeOfDay(minutes: 14 * 60))
        let items = [flex("a")]
        #expect(starts(run(items, schedule: schedule), items) == ["a": "15:00"])
    }

    @Test func zeroLengthBusyIgnored() {
        let point = DateInterval(start: Fixture.date("2026-10-01 11:00"), duration: 0)
        let items = [flex("a")]
        #expect(starts(run(items, busy: [point]), items) == ["a": "11:00"])
    }

    @Test func unplacedKeepsItsTimeAndBlocks() {
        let items = [
            flex("far", notBefore: "2026-10-01 11:00", due: "2026-10-01 11:00", minutes: 1000, created: 1),
            flex("b", notBefore: "2026-10-01 11:00", created: 2),
        ]
        let plan = run(items)
        #expect(plan.unplaced == ["far"])
        #expect(starts(plan, items)["far"] == "11:00")
        #expect(starts(plan, items)["b"] == "Fri 09:30")
    }

    @Test func unusableScheduleMovesNothing() {
        var schedule = WorkSchedule.standard
        schedule.workingDays = []
        let items = [flex("a", notBefore: "2026-10-01 11:00", due: "2026-10-01 16:00")]
        #expect(run(items, schedule: schedule).placements.isEmpty)
    }

    @Test func stableOnReplan() {
        var schedule = WorkSchedule.standard
        schedule.lunch = Lunch(minutes: 45, from: TimeOfDay(minutes: 12 * 60), to: TimeOfDay(minutes: 14 * 60))
        let items = [
            flex("a", created: 1), flex("b", created: 2), flex("c", deadline: "2026-10-01 12:00", created: 3),
            flex("long", minutes: 90, created: 4), flex("now", due: "2026-10-01 18:00", created: 5),
            flex("soon", notBefore: "2026-10-01 10:00", due: "2026-10-01 10:55", created: 6),
        ]
        let meeting = [busy("2026-10-01 11:30", "2026-10-01 12:15")]
        let first = run(items, busy: meeting, schedule: schedule, touched: "now", isNew: true)
        #expect(!first.placements.isEmpty)
        let second = run(applied(first, to: items), busy: meeting, schedule: schedule)
        #expect(second.placements.isEmpty)
    }

    @Test func editedReminderKeepsTheLeadAndTheFreeze() {
        let now = Fixture.date("2026-10-01 11:47")
        var edited = flex("a", notBefore: "2026-10-01 11:00", due: "2026-10-01 12:50")
        edited.updatedAt = now
        for scope in [PlanScope.all, .only("a")] {
            let plan = run([edited], now: now, scope: scope, touched: "a")
            let start = plan.placements.first?.to ?? edited.dueAt
            #expect(start >= Fixture.date("2026-10-01 12:02"))
        }
        // Inside the freeze window, an edit does not pull it out of its slot.
        let close = flex("c", notBefore: "2026-10-01 11:00", due: "2026-10-01 11:55")
        #expect(run([close], now: now, scope: .only("c"), touched: "c").placements.isEmpty)
    }

    @Test func unplacedKeepsItsOwnTime() {
        var schedule = WorkSchedule.standard
        schedule.end = TimeOfDay(minutes: 9 * 60 + 30 + 30)
        schedule.start = TimeOfDay(minutes: 9 * 60 + 30)
        let items = [flex("a", notBefore: "2026-10-01 10:00", due: "2026-10-03 11:00", minutes: 60)]
        let plan = run(items, schedule: schedule)
        #expect(plan.unplaced == ["a"])
        #expect(plan.placements.isEmpty)
    }

    @Test func unplacedNewReminderInThePastMovesToNow() {
        var schedule = WorkSchedule.standard
        schedule.end = TimeOfDay(minutes: 10 * 60)
        let items = [flex("a", notBefore: "2026-10-01 10:00", due: "2026-10-01 10:30", minutes: 60)]
        let plan = run(items, schedule: schedule, touched: "a", isNew: true)
        #expect(plan.unplaced == ["a"])
        #expect(plan.placements == [Placement(
            reminderId: "a", from: Fixture.date("2026-10-01 10:30"), to: Fixture.date("2026-10-01 10:45")
        )])
    }

    @Test func conflictsOnlyForFutureOwnerFixedReminders() {
        let interval = busy("2026-10-01 14:15", "2026-10-01 15:00")
        var auto = fixed("auto", at: "2026-10-01 14:00", minutes: 30)
        auto.fixed = false
        auto.autoRun = "ask"
        var fired = fixed("fired", at: "2026-10-01 14:00", minutes: 30)
        fired.fixed = false
        fired.firedAt = Fixture.now
        let overdue = fixed("overdue", at: "2026-10-01 10:00", minutes: 30)
        let plan = run([auto, fired, overdue], busy: [busy("2026-10-01 09:50", "2026-10-01 10:20"), interval])
        #expect(plan.conflicts.isEmpty)
    }
}
