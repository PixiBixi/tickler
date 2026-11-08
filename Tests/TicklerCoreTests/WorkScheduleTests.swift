import Foundation
import Testing
@testable import TicklerCore

struct WorkScheduleTests {
    @Test func parsesDays() {
        #expect(WorkSchedule.parseDays("mon-fri") == [2, 3, 4, 5, 6])
        #expect(WorkSchedule.parseDays("mon,tue,thu") == [2, 3, 5])
        #expect(WorkSchedule.parseDays("sat-sun") == [7, 1])
    }

    @Test func parseRejectsEmptyDaysAndInvertedHours() {
        #expect(WorkSchedule.parseDays("") == nil)
        #expect(WorkSchedule.parseDays("mon-xyz") == nil)
        #expect(WorkSchedule.parseHours("19:30-09:30") == nil)
        #expect(WorkSchedule.parseHours("09:30-09:30") == nil)
        #expect(WorkSchedule.parseDuration("0m") == nil)
        #expect(WorkSchedule.parseDuration("2d") == nil)
        #expect(WorkSchedule.parseDuration("999999999999999999h") == nil)
    }

    @Test func parsesDurationAndLunch() throws {
        #expect(WorkSchedule.parseDuration("90m") == 90)
        #expect(WorkSchedule.parseDuration("1h") == 60)
        #expect(WorkSchedule.parseLunch("off") == .some(nil))
        let noon = try #require(TimeOfDay("12:00"))
        let two = try #require(TimeOfDay("14:00"))
        #expect(WorkSchedule.parseLunch("45m@12:00-14:00") == Lunch(minutes: 45, from: noon, to: two))
        #expect(WorkSchedule.parseLunch("3h@12:00-14:00") == nil) // longer than its window
    }

    @Test func textRoundTrips() {
        #expect(TimeOfDay("09:30")?.minutes == 570)
        #expect(TimeOfDay("9:30") == nil)
        #expect(TimeOfDay("24:00") == nil)
        #expect(WorkSchedule.standard.daysText == "mon-fri")
        #expect(WorkSchedule.parseDays(WorkSchedule.standard.daysText) == WorkSchedule.standard.workingDays)
        #expect(WorkSchedule.standard.workingMinutes == 600)
    }

    @Test func storeDefaultsThenRoundTrips() throws {
        let store = try Fixture.store()
        #expect(try store.schedule() == .standard)
        #expect(WorkSchedule.standard.hoursText == "09:30-19:30")
        var edited = WorkSchedule.standard
        edited.defaultDurationMinutes = 30
        try store.setSchedule(edited)
        #expect(try store.schedule().defaultDurationMinutes == 30)
    }

    @Test func busySnapshotAtRoundTrips() throws {
        let store = try Fixture.store()
        #expect(try store.busySnapshotAt() == nil)
        try store.setBusySnapshotAt(Fixture.now)
        #expect(try store.busySnapshotAt() == Fixture.now)
    }
}
