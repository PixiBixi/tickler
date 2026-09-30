import Foundation
import Testing
@testable import TicklerCore

struct CalendarMarkerTests {
    @Test func findsTheReminderFromTheURLOrTheNotes() {
        #expect(CalendarMarker.reminderId(url: URL(string: "tickler://open/abc234"), notes: nil) == "abc234")
        #expect(CalendarMarker.reminderId(url: nil, notes: "some notes\n\ntickler://open/xyz789") == "xyz789")
        #expect(CalendarMarker.reminderId(url: URL(string: "https://example.org"), notes: "no marker") == nil)
        #expect(CalendarMarker.reminderId(url: nil, notes: nil) == nil)
    }

    @Test func notesEndWithTheMarker() {
        let due = Fixture.date("2026-10-02 09:30")
        let reminder = Reminder(
            id: "abc234", title: "t", notes: "Check the MR", dueAt: due, originalDueAt: due, rescheduleCount: 0, status: .open,
            sessionId: nil, cwd: nil, source: .claude, externalRef: nil, notifiedAt: nil, doneAt: nil, createdAt: due, updatedAt: due
        )
        let link = ReminderLink(reminderId: "abc234", position: 0, url: "https://example.org/x", kind: .other, label: "example.org")
        let notes = CalendarMarker.notes(for: reminder, links: [link])
        #expect(notes == "Check the MR\n\nexample.org: https://example.org/x\n\ntickler://open/abc234")
        #expect(CalendarMarker.reminderId(url: nil, notes: notes) == "abc234")
    }
}
