import Foundation
import Testing
@testable import TicklerCore

struct SnoozePresetTests {
    func format(_ preset: SnoozePreset, _ now: Date = Fixture.now) -> String? {
        preset.date(from: now, calendar: Fixture.calendar).map { StrictDate.format($0, calendar: Fixture.calendar) }
    }

    @Test func datesFromThursdayMorning() {
        #expect(format(.fifteenMinutes) == "2026-10-01 11:00")
        #expect(format(.oneHour) == "2026-10-01 11:45")
        #expect(format(.thisAfternoon) == "2026-10-01 14:00")
        #expect(format(.tomorrowMorning) == "2026-10-02 09:30")
        #expect(format(.nextMonday) == "2026-10-05 09:30")
    }

    @Test func afternoonDisappearsWhenTooClose() {
        let lateLunch = Fixture.date("2026-10-01 13:40")
        #expect(format(.thisAfternoon, lateLunch) == nil)
        #expect(!SnoozePreset.available(now: lateLunch, calendar: Fixture.calendar).contains(.thisAfternoon))
    }

    @Test func mondayFromAMondayMeansNextWeek() {
        #expect(format(.nextMonday, Fixture.date("2026-10-05 08:00")) == "2026-10-12 09:30")
    }
}
