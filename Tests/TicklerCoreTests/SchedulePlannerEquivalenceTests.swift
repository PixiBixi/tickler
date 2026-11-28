import Foundation
import Testing
@testable import TicklerCore

/// SplitMix64: the same seed gives the same case on every machine.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct PlanCase: Sendable {
    var reminders: [Reminder]
    var busy: [DateInterval]
    var schedule: WorkSchedule
    var now: Date
    var scope: PlanScope
    var touched: String?
    var touchedIsNew: Bool
}

private enum CaseMaker {
    /// Spring and autumn DST weeks, plus the fixture day.
    static let anchors = ["2026-10-01 10:45", "2026-10-23 16:20", "2027-03-26 08:10", "2026-12-31 18:55"].map(Fixture.date)

    static func make(seed: UInt64, maxReminders: Int, maxBusy: Int) -> PlanCase {
        var rng = SeededGenerator(state: seed)
        let now = anchors.randomElement(using: &rng)!.addingTimeInterval(Double(Int.random(in: -7200 ... 7200, using: &rng)))
        let schedule = schedule(using: &rng)
        let busy = (0 ..< Int.random(in: 0 ... maxBusy, using: &rng)).map { _ in busyBlock(around: now, using: &rng) }
        var reminders = (0 ..< Int.random(in: 0 ... maxReminders, using: &rng)).map { index in
            reminder(index, around: now, using: &rng)
        }
        reminders.shuffle(using: &rng)
        var scope = PlanScope.all
        var touched: String?
        var isNew = false
        if !reminders.isEmpty, Int.random(in: 0 ..< 4, using: &rng) == 0 {
            let id = reminders.randomElement(using: &rng)!.id
            touched = id
            isNew = Bool.random(using: &rng)
            scope = Bool.random(using: &rng) ? .only(id) : .all
        }
        return PlanCase(reminders: reminders, busy: busy, schedule: schedule, now: now, scope: scope, touched: touched, touchedIsNew: isNew)
    }

    private static func schedule(using rng: inout SeededGenerator) -> WorkSchedule {
        var days: Set<Int> = Int.random(in: 0 ..< 3, using: &rng) == 0 ? Set((1 ... 7).filter { _ in Bool.random(using: &rng) }) : [
            2,
            3,
            4,
            5,
            6,
        ]
        if Int.random(in: 0 ..< 40, using: &rng) == 0 {
            days = []
        }
        let start = Int.random(in: 6 * 60 ... 11 * 60, using: &rng) / 5 * 5 + (Int.random(in: 0 ..< 10, using: &rng) == 0 ? 3 : 0)
        let end = Int.random(in: 0 ..< 30, using: &rng) == 0 ? start - 60 : Int.random(in: 15 * 60 ... 23 * 60 + 59, using: &rng)
        var lunch: Lunch?
        if Bool.random(using: &rng) {
            let from = Int.random(in: 11 * 60 ... 13 * 60, using: &rng)
            lunch = Lunch(
                minutes: [0, 30, 45, 60, 120, 500].randomElement(using: &rng)!,
                from: TimeOfDay(minutes: from),
                to: TimeOfDay(minutes: from + Int.random(in: -30 ... 180, using: &rng))
            )
        }
        let mode: SchedulingMode = Int.random(in: 0 ..< 6, using: &rng) == 0 ? [.off, .placeOnly].randomElement(using: &rng)! : .auto
        return WorkSchedule(
            workingDays: days,
            start: TimeOfDay(minutes: start),
            end: TimeOfDay(minutes: end),
            defaultDurationMinutes: [0, 15, 30, -5].randomElement(using: &rng)!,
            lunch: lunch,
            mode: mode
        )
    }

    private static func busyBlock(around now: Date, using rng: inout SeededGenerator) -> DateInterval {
        let start = now.addingTimeInterval(Double(Int.random(in: -86400 ... 50 * 86400, using: &rng) / 60 * 60))
        let length = Int.random(in: 0 ..< 50, using: &rng) == 0 ? Int.random(in: 0 ... 3 * 86400, using: &rng) : Int.random(
            in: 0 ... 180,
            using: &rng
        ) * 60
        return DateInterval(start: start, duration: Double(length) + (Int.random(in: 0 ..< 20, using: &rng) == 0 ? 17 : 0))
    }

    private static func reminder(_ index: Int, around now: Date, using rng: inout SeededGenerator) -> Reminder {
        func offset(_ range: ClosedRange<Int>) -> Date {
            now.addingTimeInterval(Double(Int.random(in: range, using: &rng)))
        }
        let due = offset(-3 * 86400 ... 20 * 86400)
        let created = offset(-30 * 86400 ... 0).addingTimeInterval(Double(Int.random(in: 0 ... 2, using: &rng)))
        let minutes = [0, -10, 5, 15, 15, 30, 45, 60, 90, 240, 700, 200_000].randomElement(using: &rng)!
        var reminder = Reminder(
            id: String(format: "r%03d", index), title: "r\(index)", notes: "", dueAt: due, originalDueAt: due, rescheduleCount: 0,
            status: Int.random(in: 0 ..< 15, using: &rng) == 0 ? .done : .open, source: .claude, createdAt: created, updatedAt: now,
            durationMinutes: minutes
        )
        if Int.random(in: 0 ..< 5, using: &rng) > 0 {
            reminder.notBefore = Bool.random(using: &rng) ? due : offset(-86400 ... 15 * 86400)
        }
        if Int.random(in: 0 ..< 3, using: &rng) == 0 {
            reminder.deadline = offset(-86400 ... 25 * 86400)
        }
        switch Int.random(in: 0 ..< 20, using: &rng) {
        case 0, 1: reminder.fixed = true
        case 2: reminder.autoRun = "headless"
        case 3: reminder.firedAt = offset(-86400 ... 0)
        default: break
        }
        return reminder
    }
}

/// Serialized: hundreds of CPU-bound cases in parallel starve the cooperative pool the process tests time.
@Suite(.serialized)
struct SchedulePlannerEquivalenceTests {
    private static func check(_ planCase: PlanCase, seed: UInt64) async throws {
        let matches = try await offPool {
            let expected = ReferenceSchedulePlanner.plan(
                reminders: planCase.reminders, busy: planCase.busy, schedule: planCase.schedule, now: planCase.now,
                calendar: Fixture.calendar, scope: planCase.scope, touched: planCase.touched, touchedIsNew: planCase.touchedIsNew
            )
            var actual = SchedulePlanner.plan(
                reminders: planCase.reminders, busy: planCase.busy, schedule: planCase.schedule, now: planCase.now,
                calendar: Fixture.calendar, scope: planCase.scope, touched: planCase.touched, touchedIsNew: planCase.touchedIsNew
            )
            // Only the new field differs from the reference, which never sets it.
            actual.stableUntil = expected.stableUntil
            return actual == expected
        }
        #expect(matches, "seed \(seed)")
    }

    @Test(arguments: 0 ..< 300)
    func matchesTheReferenceOnSmallCases(seed: Int) async throws {
        let seed = UInt64(seed) &* 7919 &+ 1
        try await Self.check(CaseMaker.make(seed: seed, maxReminders: 40, maxBusy: 100), seed: seed)
    }

    @Test(arguments: 0 ..< 4)
    func matchesTheReferenceOnLargeCases(seed: Int) async throws {
        let seed = UInt64(seed) &+ 1_000_003
        try await Self.check(CaseMaker.make(seed: seed, maxReminders: 120, maxBusy: 450), seed: seed)
    }

    /// A packed calendar sends reminders far along the horizon and past it.
    @Test(arguments: 0 ..< 20)
    func matchesTheReferenceOnFullDays(seed: Int) async throws {
        let seed = UInt64(seed) &+ 2_000_003
        var planCase = CaseMaker.make(seed: seed, maxReminders: 30, maxBusy: 0)
        planCase.busy = (0 ..< 60).map { day in
            let start = Fixture.calendar.startOfDay(for: planCase.now).addingTimeInterval(Double(day) * 86400 + 6 * 3600)
            return DateInterval(start: start, duration: Double(16 * 3600 - (day % 7) * 1800))
        }
        try await Self.check(planCase, seed: seed)
    }
}
