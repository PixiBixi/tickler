import Foundation
import Testing
@testable import TicklerCore

/// Serialized: its seeded cases would otherwise crowd the cooperative pool the process tests time.
@Suite(.serialized)
struct ScheduleSkipTests {
    private static func run(_ store: ReminderStore, at now: Date, touched: String? = nil, isNew: Bool = false) throws -> ScheduleOutcome {
        try ScheduleRunner.run(
            store: store, now: now, calendar: Fixture.calendar, cause: .routine, touched: touched, touchedIsNew: isNew, freshBusy: true
        )
    }

    private static func flexible(_ store: ReminderStore, _ title: String, notBefore: String, minutes: Int = 30) throws -> Reminder {
        var draft = Fixture.draft(title, at: notBefore)
        draft.notBefore = Fixture.date(notBefore)
        draft.durationMinutes = minutes
        return try store.add(draft)
    }

    @Test func aRunAfterTheMovesItWroteReusesTheStamp() throws {
        let store = try Fixture.store()
        try store.markScheduleMigrated()
        try store.replaceBusy(
            [DateInterval(start: Fixture.date("2026-10-01 11:00"), end: Fixture.date("2026-10-01 12:00"))],
            at: Fixture.now
        )
        _ = try Self.flexible(store, "A", notBefore: "2026-10-01 11:00")
        let first = try Self.run(store, at: Fixture.now)
        let stamp = try #require(try store.planStamp())
        #expect(first.moves.count == 1)
        // The CLI wrote the moves; the app's run on the same data plans nothing and leaves the stamp as it is.
        let second = try Self.run(store, at: Fixture.now.addingTimeInterval(60))
        #expect(second.moves.isEmpty)
        #expect(try store.planStamp() == stamp)
    }

    @Test func aStampStopsBeforeAPlacedReminderReachesTheFreeze() throws {
        let store = try Fixture.store()
        try store.markScheduleMigrated()
        try store.replaceBusy([], at: Fixture.now)
        _ = try Self.flexible(store, "A", notBefore: "2026-10-01 12:00")
        _ = try Self.run(store, at: Fixture.now)
        let stamp = try #require(try store.planStamp())
        #expect(stamp.validUntil == Fixture.date("2026-10-01 11:45"))
        // Past it the reminder is frozen: the run replans and stamps the new state for an hour.
        _ = try Self.run(store, at: Fixture.date("2026-10-01 11:46"))
        #expect(try store.planStamp()?.validUntil == Fixture.date("2026-10-01 12:46"))
    }

    @Test func aChangedInputReplans() throws {
        let store = try Fixture.store()
        try store.markScheduleMigrated()
        try store.replaceBusy([], at: Fixture.now)
        let r = try Self.flexible(store, "A", notBefore: "2026-10-01 14:00")
        _ = try Self.run(store, at: Fixture.now)
        try store.replaceBusy(
            [DateInterval(start: Fixture.date("2026-10-01 14:00"), end: Fixture.date("2026-10-01 15:00"))],
            at: Fixture.now
        )
        let outcome = try Self.run(store, at: Fixture.now)
        #expect(outcome.moves.map(\.reminderId) == [r.id])
        #expect(try store.get(r.id)?.dueAt == Fixture.date("2026-10-01 15:00"))
    }

    @Test func aSkippedRunStillReportsConflicts() throws {
        let store = try Fixture.store()
        try store.markScheduleMigrated()
        let meeting = DateInterval(start: Fixture.date("2026-10-01 14:00"), end: Fixture.date("2026-10-01 15:00"))
        try store.replaceBusy([meeting], at: Fixture.now)
        var draft = Fixture.draft("Deploy", at: "2026-10-01 14:30")
        draft.fixed = true
        let r = try store.add(draft)
        _ = try Self.run(store, at: Fixture.now)
        let stamp = try store.planStamp()
        let outcome = try Self.run(store, at: Fixture.now.addingTimeInterval(60))
        #expect(try store.planStamp() == stamp)
        #expect(outcome.conflicts == [ScheduleConflict(reminderId: r.id, interval: meeting)])
    }

    /// The CLI and the app are two processes: the fingerprint must not follow a Set's iteration order.
    @Test func theFingerprintIgnoresSetOrder() throws {
        var roomy = Set<Int>(minimumCapacity: 64)
        for day in [6, 5, 4, 3, 2] {
            roomy.insert(day)
        }
        var first = WorkSchedule.standard
        first.workingDays = [2, 3, 4, 5, 6]
        var second = WorkSchedule.standard
        second.workingDays = roomy
        let print = { (schedule: WorkSchedule) in
            try PlanInputs(reminders: [], busy: [], schedule: schedule, calendar: Fixture.calendar).fingerprint()
        }
        #expect(try print(first) == print(second))
    }

    @Test func unchangedBusyIntervalsOnlyRestampTheAge() throws {
        let store = try Fixture.store()
        try store.markScheduleMigrated()
        let meeting = DateInterval(start: Fixture.date("2026-10-01 14:00"), end: Fixture.date("2026-10-01 15:00"))
        #expect(try store.replaceBusy([meeting], at: Fixture.now))
        #expect(try !store.replaceBusy([meeting, meeting], at: Fixture.now.addingTimeInterval(60)))
        #expect(try store.busySnapshotAt() == Fixture.now.addingTimeInterval(60))
        #expect(try store.replaceBusy([], at: Fixture.now.addingTimeInterval(120)))
        #expect(try store.busy().isEmpty)
    }

    /// Whatever the clock does between runs, a run that reuses the stamp leaves the store as a full replan would.
    @Test(arguments: 0 ..< 80)
    func aReusedStampMatchesAFullReplan(seed: Int) async throws {
        let durations = [15, 30, 60, 120, 900]
        let mismatches: [String] = try await offPool {
            var mismatches: [String] = []
            var rng = SeededGenerator(state: UInt64(seed) &+ 31337)
            let store = try Fixture.store()
            try store.markScheduleMigrated()
            var busy = (0 ..< Int.random(in: 0 ... 40, using: &rng)).map { _ in
                DateInterval(
                    start: Fixture.now.addingTimeInterval(Double(Int.random(in: -2 ... 300, using: &rng) * 900)),
                    duration: Double(Int.random(in: 1 ... 8, using: &rng) * 900)
                )
            }
            for index in 0 ..< Int.random(in: 1 ... 15, using: &rng) {
                let offset = Double(Int.random(in: -8 ... 200, using: &rng) * 600)
                var draft = ReminderDraft(title: "r\(index)", dueAt: Fixture.now.addingTimeInterval(offset))
                draft.notBefore = draft.dueAt
                draft.durationMinutes = durations[Int.random(in: 0 ..< durations.count, using: &rng)]
                draft.fixed = Int.random(in: 0 ..< 6, using: &rng) == 0
                if Int.random(in: 0 ..< 3, using: &rng) == 0 {
                    draft.deadline = draft.dueAt.addingTimeInterval(Double(Int.random(in: 0 ... 30, using: &rng) * 3600))
                }
                _ = try store.add(draft)
            }
            if seed % 4 == 0 {
                // Booked days but their last half hour: long reminders run past the horizon and stay unplaced.
                let today = Fixture.calendar.startOfDay(for: Fixture.now)
                busy += (0 ..< 60).map { DateInterval(start: today.addingTimeInterval(Double($0) * 86400 + 34200), duration: 34200) }
            }
            var now = Fixture.now
            for _ in 0 ..< 6 {
                try store.replaceBusy(busy, at: now)
                let before = try store.list(ReminderFilter(due: .all, status: .open))
                let expected = try SchedulePlanner.plan(
                    reminders: before, busy: store.busy(), schedule: store.schedule(), now: now, calendar: Fixture.calendar
                )
                let outcome = try Self.run(store, at: now)
                let moved = Dictionary(expected.placements.map { ($0.reminderId, $0.to) }, uniquingKeysWith: { first, _ in first })
                for reminder in before where try store.get(reminder.id)?.dueAt != moved[reminder.id] ?? reminder.dueAt {
                    mismatches.append("due of \(reminder.title)")
                }
                if outcome.late != expected.late {
                    mismatches.append("late")
                }
                if outcome.conflicts != expected.conflicts {
                    mismatches.append("conflicts")
                }
                now = now.addingTimeInterval(Double(Int.random(in: 0 ... 72, using: &rng) * 300 + Int.random(in: 0 ... 59, using: &rng)))
            }
            return mismatches
        }
        #expect(mismatches.isEmpty, "seed \(seed): \(mismatches)")
    }
}
