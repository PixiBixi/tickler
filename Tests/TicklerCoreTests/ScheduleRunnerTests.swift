import Foundation
import Testing
@testable import TicklerCore

struct ScheduleRunnerTests {
    private func seeded(snapshotAge: TimeInterval?, busy: [DateInterval] = []) throws -> ReminderStore {
        let store = try Fixture.store()
        if let snapshotAge {
            try store.replaceBusy(busy, at: Fixture.now.addingTimeInterval(-snapshotAge))
        }
        return store
    }

    private func run(
        _ store: ReminderStore,
        cause: ScheduleCause = .routine,
        touched: String? = nil,
        isNew: Bool = false,
        freshBusy: Bool = false
    ) throws -> ScheduleOutcome {
        try ScheduleRunner.run(
            store: store, now: Fixture.now, calendar: Fixture.calendar, cause: cause, touched: touched, touchedIsNew: isNew,
            freshBusy: freshBusy
        )
    }

    private func markMigrated(_ store: ReminderStore) throws {
        _ = try run(store)
    }

    @Test func freshCopyPlansEverything() throws {
        let store = try seeded(snapshotAge: 60)
        try markMigrated(store)
        // Anchored at 10:45 but parked at 15:00: the free slot pulls it earlier.
        var draft = Fixture.draft("A", at: "2026-10-01 15:00")
        draft.notBefore = Fixture.date("2026-10-01 10:45")
        let r = try store.add(draft)
        let outcome = try run(store)
        #expect(outcome.moves.count == 1)
        #expect(outcome.moves.first?.reason == .slotFreed)
        #expect(outcome.warning == nil)
        // The planner keeps the 15 min freeze window after now.
        #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-01 11:00"))
    }

    @Test func staleCopyOnlyPlacesTouched() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 11:15"))]
        let store = try seeded(snapshotAge: 3 * 3600, busy: busy)
        var other = Fixture.draft("Other", at: "2026-10-01 15:00")
        other.notBefore = Fixture.date("2026-10-01 10:45")
        let otherRow = try store.add(other)
        let touched = try store.add(Fixture.draft("T", at: "2026-10-01 10:45"))
        let outcome = try run(store, cause: .reminderAdded, touched: touched.id, isNew: true)
        #expect(outcome.warning?.hasPrefix("calendar copy is 3 h old") == true)
        #expect(try store.require(touched.id).dueAt == Fixture.date("2026-10-01 11:15"))
        #expect(try store.require(otherRow.id).dueAt == Fixture.date("2026-10-01 15:00"))
        #expect(outcome.moves.isEmpty)
        #expect(try store.moves(since: .distantPast, includeMigration: true).isEmpty)
    }

    @Test func staleCopyWithoutTouchedWritesNothing() throws {
        let store = try seeded(snapshotAge: 3 * 3600)
        var draft = Fixture.draft("A", at: "2026-10-01 15:00")
        draft.notBefore = Fixture.date("2026-10-01 10:45")
        let r = try store.add(draft)
        let outcome = try run(store)
        #expect(outcome.moves.isEmpty)
        #expect(outcome.warning != nil)
        #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-01 15:00"))
    }

    @Test func ancientCopyIgnoresBusy() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 12:00"))]
        let store = try seeded(snapshotAge: 3 * 86400, busy: busy)
        let touched = try store.add(Fixture.draft("T", at: "2026-10-01 10:45"))
        let outcome = try run(store, cause: .reminderAdded, touched: touched.id, isNew: true)
        #expect(outcome.warning?.hasPrefix("no recent calendar copy") == true)
        #expect(try store.require(touched.id).dueAt == Fixture.date("2026-10-01 10:45"))
    }

    @Test func missingCopyIgnoresBusy() throws {
        let store = try seeded(snapshotAge: nil)
        let touched = try store.add(Fixture.draft("T", at: "2026-10-01 10:45"))
        let outcome = try run(store, cause: .reminderAdded, touched: touched.id, isNew: true)
        #expect(outcome.warning?.hasPrefix("no recent calendar copy") == true)
    }

    @Test func freshBusyForcesScopeAll() throws {
        let store = try seeded(snapshotAge: 3 * 3600)
        try markMigrated(store)
        var draft = Fixture.draft("A", at: "2026-10-01 15:00")
        draft.notBefore = Fixture.date("2026-10-01 10:45")
        _ = try store.add(draft)
        let outcome = try run(store, freshBusy: true)
        #expect(outcome.moves.count == 1)
        #expect(outcome.warning == nil)
    }

    @Test func firstRunMovesAreMigration() throws {
        let store = try seeded(snapshotAge: 60)
        var draft = Fixture.draft("A", at: "2026-10-01 15:00")
        draft.notBefore = Fixture.date("2026-10-01 10:45")
        _ = try store.add(draft)
        let first = try run(store)
        #expect(first.moves.map(\.reason) == [.migration])
        let second = try run(store)
        #expect(second.moves.isEmpty)
    }

    @Test func dayFullReason() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 19:30"))]
        let store = try seeded(snapshotAge: 60, busy: busy)
        try markMigrated(store)
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 11:00"))
        let outcome = try run(store, cause: .calendar)
        #expect(outcome.moves.count == 1)
        #expect(outcome.moves.first?.reason == .dayFull)
        #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-02 09:30"))
    }

    @Test func causeNamesTheReason() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 11:15"))]
        let store = try seeded(snapshotAge: 60, busy: busy)
        try markMigrated(store)
        _ = try store.add(Fixture.draft("A", at: "2026-10-01 11:00"))
        let outcome = try run(store, cause: .calendar)
        #expect(outcome.moves.map(\.reason) == [.meeting])
    }

    @Test func touchedPlacementHasNoMoveRow() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 11:15"))]
        let store = try seeded(snapshotAge: 60, busy: busy)
        try markMigrated(store)
        let touched = try store.add(Fixture.draft("T", at: "2026-10-01 11:00"))
        let outcome = try run(store, cause: .reminderAdded, touched: touched.id, isNew: true)
        #expect(outcome.moves.isEmpty)
        #expect(try store.require(touched.id).dueAt == Fixture.date("2026-10-01 11:15"))
        #expect(try store.moves(since: .distantPast, includeMigration: true).isEmpty)
    }

    @Test func routineReplanIsNotAMeeting() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 11:15"))]
        let store = try seeded(snapshotAge: 60, busy: busy)
        try markMigrated(store)
        _ = try store.add(Fixture.draft("A", at: "2026-10-01 11:00"))
        #expect(try run(store, cause: .routine).moves.map(\.reason) == [.replanned])
    }

    @Test func unplacedReminderIsNotMovedNorLogged() throws {
        let store = try seeded(snapshotAge: 60)
        try markMigrated(store)
        var schedule = try store.schedule()
        schedule.start = TimeOfDay(minutes: 8 * 60)
        schedule.end = TimeOfDay(minutes: 8 * 60 + 30)
        try store.setSchedule(schedule)
        var draft = Fixture.draft("Long", at: "2026-10-03 11:00")
        draft.notBefore = Fixture.date("2026-10-01 11:00")
        draft.durationMinutes = 60
        let r = try store.add(draft)
        let outcome = try run(store)
        #expect(outcome.unplaced == [r.id])
        #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-03 11:00"))
        #expect(try store.moves(since: .distantPast, includeMigration: true).isEmpty)
    }

    @Test func missingCopyBehavesLikeAnAncientOne() throws {
        let store = try seeded(snapshotAge: nil)
        var draft = Fixture.draft("A", at: "2026-10-01 15:00")
        draft.notBefore = Fixture.date("2026-10-01 10:45")
        let other = try store.add(draft)
        let new = try store.add(Fixture.draft("T", at: "2026-10-01 10:45"))
        let outcome = try run(store, cause: .reminderAdded, touched: new.id, isNew: true)
        #expect(outcome.warning?.hasPrefix("no recent calendar copy") == true)
        #expect(try store.require(new.id).dueAt == Fixture.date("2026-10-01 10:45"))
        #expect(try store.require(other.id).dueAt == Fixture.date("2026-10-01 15:00"))
    }

    @Test func editedReminderDoesNotJumpIntoTheFreezeWindow() throws {
        let store = try seeded(snapshotAge: 60)
        try markMigrated(store)
        var draft = Fixture.draft("A", at: "2026-10-01 12:50")
        draft.notBefore = Fixture.date("2026-10-01 11:00")
        let r = try store.add(draft)
        let late = Fixture.now.addingTimeInterval(62 * 60)
        _ = try ScheduleRunner.run(
            store: store, now: late, calendar: Fixture.calendar, cause: .routine, touched: r.id, freshBusy: true
        )
        #expect(try store.require(r.id).dueAt >= late.addingTimeInterval(15 * 60))
    }
}
