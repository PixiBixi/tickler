import Foundation
import Testing
@testable import TicklerCore

/// Frozen now: Thursday 2026-10-01 10:45, Paris.
struct DateParserTests {
    let parser = DateParser(preferred: "fr")

    func parse(_ input: String) -> String? {
        parser.parse(input, now: Fixture.now, calendar: Fixture.calendar).map { StrictDate.format($0, calendar: Fixture.calendar) }
    }

    @Test(arguments: [
        ("demain 9h30", "2026-10-02 09:30"),
        ("Demain 9h", "2026-10-02 09:00"),
        ("demain", "2026-10-02 09:00"),
        ("après-demain 14h", "2026-10-03 14:00"),
        ("lundi 10h", "2026-10-05 10:00"),
        ("jeudi 14h", "2026-10-08 14:00"),
        ("vendredi", "2026-10-02 09:00"),
        ("dans 2h", "2026-10-01 12:45"),
        ("dans 30 min", "2026-10-01 11:15"),
        ("dans 1 h 30", "2026-10-01 12:15"),
        ("dans 3 jours", "2026-10-04 10:45"),
        ("15:00", "2026-10-01 15:00"),
        ("15h", "2026-10-01 15:00"),
        ("9h", "2026-10-02 09:00"),
        ("aujourd'hui 18h", "2026-10-01 18:00"),
        ("ce soir", "2026-10-01 18:00"),
        ("cet après-midi", "2026-10-01 14:00"),
        ("lundi prochain 9h30", "2026-10-05 09:30"),
        ("le 6 octobre à 10h", "2026-10-06 10:00"),
        ("6/10 10h", "2026-10-06 10:00"),
    ])
    func french(input: String, expected: String) {
        #expect(parse(input) == expected)
    }

    @Test(arguments: [
        ("tomorrow 9:30am", "2026-10-02 09:30"),
        ("tomorrow at 3pm", "2026-10-02 15:00"),
        ("monday 10am", "2026-10-05 10:00"),
        ("next monday 10am", "2026-10-05 10:00"),
        ("in 2h", "2026-10-01 12:45"),
        ("in 45 minutes", "2026-10-01 11:30"),
        ("in 2 days", "2026-10-03 10:45"),
        ("3pm", "2026-10-01 15:00"),
        ("9am", "2026-10-02 09:00"),
        ("today 6pm", "2026-10-01 18:00"),
        ("tonight", "2026-10-01 18:00"),
        ("oct 6 10am", "2026-10-06 10:00"),
    ])
    func english(input: String, expected: String) {
        #expect(parse(input) == expected)
    }

    @Test func isoIsAlwaysAccepted() {
        #expect(parse("2026-10-06 10:00") == "2026-10-06 10:00")
    }

    @Test(arguments: ["", "n'importe quoi", "2026-09-01 10:00", "hier 10h", "25h", "2026-02-31 10:00", "dans -2h"])
    func rejects(input: String) {
        #expect(parse(input) == nil)
    }

    @Test func englishPreferredStillReadsFrench() {
        let english = DateParser(preferred: "en")
        let date = english.parse("demain 9h30", now: Fixture.now, calendar: Fixture.calendar)
        #expect(date == Fixture.date("2026-10-02 09:30"))
    }
}

struct DueBucketTests {
    @Test(arguments: [
        ("2026-10-01 09:30", DueBucket.overdue),
        ("2026-10-01 11:00", .today),
        ("2026-10-01 23:59", .today),
        ("2026-10-02 00:00", .tomorrow),
        ("2026-10-02 23:00", .tomorrow),
        ("2026-10-05 09:30", .later),
    ])
    func buckets(due: String, bucket: DueBucket) {
        #expect(DueBucket.of(Fixture.date(due), now: Fixture.now, calendar: Fixture.calendar) == bucket)
    }
}

struct StrictDateTests {
    @Test func roundTrips() {
        let date = Fixture.date("2026-10-06 10:00")
        #expect(StrictDate.format(date, calendar: Fixture.calendar) == "2026-10-06 10:00")
    }

    @Test(arguments: ["2026-10-06", "10:00", "2026-13-01 10:00", "2026-10-06 24:00", "2026/10/06 10:00"])
    func rejects(value: String) {
        #expect(StrictDate.parse(value, calendar: Fixture.calendar) == nil)
    }
}
