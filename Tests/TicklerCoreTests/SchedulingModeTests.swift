import Foundation
import Testing
@testable import TicklerCore

struct SchedulingModeTests {
    private func store(mode: SchedulingMode, busy: [DateInterval] = []) throws -> ReminderStore {
        let store = try Fixture.store()
        try store.replaceBusy(busy, at: Fixture.now.addingTimeInterval(-60))
        var schedule = try store.schedule()
        schedule.mode = mode
        try store.setSchedule(schedule)
        return store
    }

    private func run(_ store: ReminderStore, touched: String? = nil, isNew: Bool = false) throws -> ScheduleOutcome {
        try ScheduleRunner.run(
            store: store, now: Fixture.now, calendar: Fixture.calendar, cause: .routine, touched: touched, touchedIsNew: isNew
        )
    }

    private func anchored(_ store: ReminderStore) throws -> Reminder {
        var draft = Fixture.draft("A", at: "2026-10-01 15:00")
        draft.notBefore = Fixture.date("2026-10-01 10:45")
        return try store.add(draft)
    }

    @Test func autoFillsAFreedSlot() throws {
        let store = try store(mode: .auto)
        _ = try run(store)
        let reminder = try anchored(store)
        _ = try run(store)
        #expect(try store.require(reminder.id).dueAt == Fixture.date("2026-10-01 11:00"))
    }

    @Test(arguments: [SchedulingMode.placeOnly, .off])
    func otherModesLeaveAFreedSlotEmpty(mode: SchedulingMode) throws {
        let store = try store(mode: mode)
        _ = try run(store)
        let reminder = try anchored(store)
        let outcome = try run(store)
        #expect(outcome.moves.isEmpty)
        #expect(try store.require(reminder.id).dueAt == Fixture.date("2026-10-01 15:00"))
    }

    @Test func migrationRepackOnlyRunsInAuto() throws {
        let store = try store(mode: .placeOnly)
        let reminder = try anchored(store)
        _ = try run(store)
        #expect(try store.isScheduleMigrated())
        #expect(try store.require(reminder.id).dueAt == Fixture.date("2026-10-01 15:00"))
        #expect(try store.moves(since: .distantPast, includeMigration: true).isEmpty)
    }

    @Test func placeOnlyPlacesANewReminderAroundBusy() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 11:15"))]
        let store = try store(mode: .placeOnly, busy: busy)
        let new = try store.add(Fixture.draft("T", at: "2026-10-01 10:45"))
        _ = try run(store, touched: new.id, isNew: true)
        #expect(try store.require(new.id).dueAt == Fixture.date("2026-10-01 11:15"))
    }

    @Test func offClampsANewReminderIgnoringBusy() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-02 09:30"), end: Fixture.date("2026-10-02 10:00"))]
        let store = try store(mode: .off, busy: busy)
        var draft = Fixture.draft("T", at: "2026-10-01 20:00")
        draft.notBefore = Fixture.date("2026-10-01 20:00")
        let new = try store.add(draft)
        _ = try run(store, touched: new.id, isNew: true)
        #expect(try store.require(new.id).dueAt == Fixture.date("2026-10-02 09:30"))
    }

    @Test func offKeepsAnEarliestStartInsideWorkingTime() throws {
        let busy = [DateInterval(start: Fixture.date("2026-10-01 10:45"), end: Fixture.date("2026-10-01 11:15"))]
        let store = try store(mode: .off, busy: busy)
        let new = try store.add(Fixture.draft("T", at: "2026-10-01 10:45"))
        _ = try run(store, touched: new.id, isNew: true)
        #expect(try store.require(new.id).dueAt == Fixture.date("2026-10-01 10:45"))
    }

    @Test func legacyJSONDecodesToAuto() throws {
        let json = """
        {"workingDays":[2,3],"start":{"minutes":570},"end":{"minutes":1170},"defaultDurationMinutes":15,"busyCalendarIds":[]}
        """
        let schedule = try JSONDecoder().decode(WorkSchedule.self, from: Data(json.utf8))
        #expect(schedule.mode == .auto)
    }

    @Test func modeRoundTripsThroughTheStore() throws {
        let store = try store(mode: .placeOnly)
        #expect(try store.schedule().mode == .placeOnly)
    }

    @Test(arguments: [SchedulingMode.placeOnly, .off])
    func pinnedFlexibleReminderUnderAMeetingIsFlagged(mode: SchedulingMode) throws {
        let meeting = DateInterval(start: Fixture.date("2026-10-01 14:45"), end: Fixture.date("2026-10-01 15:30"))
        let store = try store(mode: mode, busy: [meeting])
        _ = try run(store)
        let reminder = try anchored(store)
        let outcome = try run(store)
        #expect(try store.require(reminder.id).dueAt == Fixture.date("2026-10-01 15:00"))
        #expect(outcome.conflicts.map(\.reminderId) == [reminder.id])
    }
}
