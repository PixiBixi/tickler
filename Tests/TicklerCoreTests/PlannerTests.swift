import Foundation
import Testing
@testable import TicklerCore

private func reminder(
    _ id: String,
    at due: String,
    status: Reminder.Status = .open,
    notified: Bool = false,
    title: String = "t"
) -> Reminder {
    let date = Fixture.date(due)
    return Reminder(
        id: id, title: title, notes: "", dueAt: date, originalDueAt: date, rescheduleCount: 0, status: status,
        sessionId: nil, cwd: nil, source: .claude, externalRef: nil, notifiedAt: notified ? Fixture.now : nil,
        doneAt: nil, createdAt: Fixture.now, updatedAt: Fixture.now
    )
}

private func link(_ id: String, _ url: String) -> ReminderLink {
    let (kind, label) = LinkExtractor.classify(URL(string: url)!)
    return ReminderLink(reminderId: id, position: 0, url: url, kind: kind, label: label)
}

struct NotificationPlannerTests {
    @Test func schedulesFutureOpenRemindersOnly() {
        let reminders = [
            reminder("past01", at: "2026-10-01 09:30"),
            reminder("next01", at: "2026-10-01 11:00"),
            reminder("done01", at: "2026-10-01 12:00", status: .done),
        ]
        let plan = NotificationPlanner.plan(reminders: reminders, links: [:], pendingIds: [], now: Fixture.now)
        #expect(plan.add.map(\.reminder.id) == ["next01"])
        #expect(plan.remove.isEmpty)
    }

    @Test func keepsAlreadyPendingAndRemovesStale() {
        let current = reminder("keep01", at: "2026-10-01 11:00")
        let keepId = NotificationPlanner.requestId(for: current)
        let plan = NotificationPlanner.plan(
            reminders: [current], links: [:], pendingIds: [keepId, "gone01@1790000000"], now: Fixture.now
        )
        #expect(plan.add.isEmpty)
        #expect(plan.remove == ["gone01@1790000000"])
    }

    @Test func rescheduleReplacesTheRequest() {
        let before = reminder("move01", at: "2026-10-01 11:00")
        var after = before
        after.dueAt = Fixture.date("2026-10-01 12:00")
        let plan = NotificationPlanner.plan(
            reminders: [after], links: [:], pendingIds: [NotificationPlanner.requestId(for: before)], now: Fixture.now
        )
        #expect(plan.add.map(\.id) == [NotificationPlanner.requestId(for: after)])
        #expect(plan.remove == [NotificationPlanner.requestId(for: before)])
    }

    @Test func capsToTheNearest() {
        let reminders = (0 ..< 70).map { index in
            reminder(
                "r\(index)",
                at: StrictDate.format(Fixture.now.addingTimeInterval(Double(70 - index) * 3600), calendar: Fixture.calendar)
            )
        }
        let plan = NotificationPlanner.plan(reminders: reminders, links: [:], pendingIds: [], now: Fixture.now, limit: 64)
        #expect(plan.add.count == 64)
        #expect(!plan.add.contains { $0.reminder.id == "r0" })
        #expect(plan.add.first?.reminder.id == "r69")
    }

    @Test func categoryFollowsLinks() {
        let withTicket = reminder("tick01", at: "2026-10-01 11:00")
        let links = ["tick01": [
            link("tick01", "https://acme.atlassian.net/browse/OPS-1"),
            link("tick01", "https://acme.slack.com/archives/C1/p1"),
        ]]
        let plan = NotificationPlanner.plan(reminders: [withTicket], links: links, pendingIds: [], now: Fixture.now)
        #expect(plan.add.first?.category == .ticketSlack)
    }

    @Test func catchUpIgnoresNotifiedAndStillPending() {
        let shown = reminder("seen01", at: "2026-10-01 08:00", notified: true)
        let pending = reminder("pend01", at: "2026-10-01 09:00")
        let missed = reminder("miss01", at: "2026-10-01 10:00")
        let future = reminder("futu01", at: "2026-10-01 12:00")
        let result = NotificationPlanner.catchUp(
            reminders: [shown, pending, missed, future],
            alreadyShownIds: [NotificationPlanner.requestId(for: pending)],
            now: Fixture.now
        )
        #expect(result == .individual([missed]))
    }

    @Test func catchUpSummarizesBeyondThree() {
        let missed = (0 ..< 4).map { reminder("m\($0)", at: "2026-10-01 0\($0 + 5):00") }
        let result = NotificationPlanner.catchUp(reminders: missed, alreadyShownIds: [], now: Fixture.now)
        #expect(result == .summary(missed))
        #expect(NotificationPlanner.catchUp(reminders: [], alreadyShownIds: [], now: Fixture.now) == .none)
    }
}

struct NotificationCategoryTests {
    @Test(arguments: [
        ([String](), NotificationCategory.plain),
        (["https://acme.atlassian.net/browse/OPS-1"], .ticket),
        (["https://acme.slack.com/archives/C1/p1"], .slack),
        (["https://gitlab.com/a/b/-/merge_requests/1"], .link),
        (["https://acme.atlassian.net/browse/OPS-1", "https://gitlab.com/a/b/-/merge_requests/1"], .ticketLink),
        (["https://acme.slack.com/archives/C1/p1", "https://gitlab.com/a/b/-/merge_requests/1"], .slack),
    ])
    func category(urls: [String], expected: NotificationCategory) {
        #expect(NotificationCategory.for(links: urls.map { link("x", $0) }) == expected)
    }

    @Test func targetsPickTheFirstOfEachKind() {
        let links = [
            link("x", "https://gitlab.com/a/b/-/merge_requests/1"),
            link("x", "https://acme.atlassian.net/browse/OPS-1"),
            link("x", "https://acme.atlassian.net/browse/OPS-2"),
        ]
        let targets = LinkTargets(links: links)
        #expect(targets.ticket?.label == "OPS-1")
        #expect(targets.slack == nil)
        #expect(targets.other?.label == "b !1")
    }
}

struct CalendarPlannerTests {
    let calendarId = "cal-claude"

    func mapping(_ reminder: Reminder, calendar: String? = nil, hash: String? = nil) -> CalendarMapping {
        CalendarMapping(
            reminderId: reminder.id, eventIdentifier: "ev-\(reminder.id)", calendarId: calendar ?? calendarId,
            syncedHash: hash ?? CalendarPlanner.contentHash(reminder, links: [])
        )
    }

    func plan(_ reminders: [Reminder], _ mappings: [CalendarMapping]) -> [CalendarAction] {
        CalendarPlanner.plan(reminders: reminders, links: [:], mappings: mappings, calendarId: calendarId, now: Fixture.now)
    }

    @Test func createsMissingEvents() {
        let fresh = reminder("new001", at: "2026-10-02 09:30")
        #expect(plan([fresh], []) == [.create(fresh, hash: CalendarPlanner.contentHash(fresh, links: []))])
    }

    @Test func leavesUnchangedEventsAlone() {
        let same = reminder("same01", at: "2026-10-02 09:30")
        #expect(plan([same], [mapping(same)]).isEmpty)
    }

    @Test func updatesWhenContentChanged() {
        let old = reminder("edit01", at: "2026-10-02 09:30", title: "old")
        let new = reminder("edit01", at: "2026-10-02 10:30", title: "new")
        #expect(plan([new], [mapping(old)]) == [
            .update(new, eventIdentifier: "ev-edit01", hash: CalendarPlanner.contentHash(new, links: [])),
        ])
    }

    @Test func deletesDoneDeletedAndMissing() {
        let done = reminder("done01", at: "2026-10-02 09:30", status: .done)
        let deleted = reminder("dele01", at: "2026-10-02 09:30", status: .deleted)
        let orphan = CalendarMapping(reminderId: "orph01", eventIdentifier: "ev-orph01", calendarId: calendarId, syncedHash: "x")
        let actions = plan([done, deleted], [mapping(done), mapping(deleted), orphan])
        #expect(Set(actions) == [
            .delete(eventIdentifier: "ev-done01", reminderId: "done01"),
            .delete(eventIdentifier: "ev-dele01", reminderId: "dele01"),
            .delete(eventIdentifier: "ev-orph01", reminderId: "orph01"),
        ])
    }

    @Test func respectsTheWindow() {
        let old = reminder("old001", at: "2026-09-20 09:30")
        let far = reminder("far001", at: "2026-12-15 09:30")
        let recentOverdue = reminder("late01", at: "2026-09-28 09:30")
        let actions = plan([old, far, recentOverdue], [mapping(old)])
        #expect(Set(actions) == [
            .delete(eventIdentifier: "ev-old001", reminderId: "old001"),
            .create(recentOverdue, hash: CalendarPlanner.contentHash(recentOverdue, links: [])),
        ])
    }

    @Test func calendarChangeMovesEvents() {
        let moved = reminder("move01", at: "2026-10-02 09:30")
        let actions = plan([moved], [mapping(moved, calendar: "cal-old")])
        #expect(actions == [
            .delete(eventIdentifier: "ev-move01", reminderId: "move01"),
            .create(moved, hash: CalendarPlanner.contentHash(moved, links: [])),
        ])
    }

    @Test func hashChangesWithLinks() {
        let base = reminder("hash01", at: "2026-10-02 09:30")
        let withLink = CalendarPlanner.contentHash(base, links: [link("hash01", "https://acme.atlassian.net/browse/OPS-1")])
        #expect(withLink != CalendarPlanner.contentHash(base, links: []))
    }
}
