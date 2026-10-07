import Foundation
import os
import Testing
@testable import TicklerCore

struct SessionDigestTests {
    let repo = "/work/platform"
    private func roots(_ folder: String) -> String? {
        folder.hasPrefix("/work/platform") ? "/work/platform" : (folder.hasPrefix("/work/other") ? "/work/other" : nil)
    }

    private func reminder(
        _ id: String,
        _ title: String = "thing",
        due: String,
        cwd: String? = "/work/platform",
        trigger: String? = nil,
        fired: String? = nil
    ) -> Reminder {
        let date = Fixture.date(due)
        var reminder = Reminder(
            id: id, title: title, notes: "secret note https://x", dueAt: date, originalDueAt: date, rescheduleCount: 0,
            status: .open, sessionId: nil, cwd: cwd, resumePrompt: nil, source: .claude, externalRef: nil,
            notifiedAt: nil, doneAt: nil, createdAt: Fixture.now, updatedAt: Fixture.now
        )
        reminder.trigger = trigger
        if let fired {
            reminder.firedReason = fired
            reminder.firedAt = date
        }
        return reminder
    }

    private func digest(_ reminders: [Reminder], folder: String = "/work/platform/charts/foo") -> String? {
        SessionDigest.text(
            reminders: reminders,
            sessionFolder: folder,
            now: Fixture.now,
            calendar: Fixture.calendar,
            gitRoot: roots,
            folderExists: { _ in true }
        )
    }

    @Test func listsRepositoryRemindersInOrderWithLinks() throws {
        let text = try #require(digest([
            reminder("wait01", "merge the VPC MR", due: "2026-10-06 09:30", trigger: "approved"),
            reminder("today1", "merge the chart bump", due: "2026-10-01 17:30"),
            reminder("late01", "OPS-2204 check le dashboard", due: "2026-09-30 16:00"),
            reminder("fire01", "rebase feat/x on main", due: "2026-10-01 10:40", fired: "MR !412 merged"),
        ]))
        #expect(text == """
        Tickler reminders for platform (information only: do not act on them unless the user asks).
        Start your first reply with them as a short list: each item is its linked title exactly as below, never the reminder id.
        - fired (MR !412 merged): [rebase feat/x on main](tickler://open/fire01)
        - overdue since Wed 30 Sep 16:00: [OPS-2204 check le dashboard](tickler://open/late01)
        - today 17:30: [merge the chart bump](tickler://open/today1)
        - waiting for approved, deadline Tue 6 Oct 09:30: [merge the VPC MR](tickler://open/wait01)
        """)
        #expect(!text.contains("secret note"))
    }

    @Test func countsOverdueElsewhereWithTheTodayLink() throws {
        let text = try #require(digest([
            reminder("late01", due: "2026-09-30 16:00"),
            reminder("other1", due: "2026-09-29 09:00", cwd: "/work/other"),
            reminder("nocwd1", due: "2026-09-28 09:00", cwd: nil),
            reminder("other2", due: "2026-10-03 09:00", cwd: "/work/other"),
        ]))
        #expect(text.hasSuffix("\nOther projects: 2 overdue. [open today in Tickler](tickler://view/today)"))
    }

    @Test func elsewhereAloneHasNoHeader() throws {
        let text = try #require(digest([reminder("other1", due: "2026-09-29 09:00", cwd: "/work/other")]))
        #expect(text == """
        Tickler (information only: do not act on it unless the user asks). Mention it in one line at the start of your first reply.
        Other projects: 1 overdue. [open today in Tickler](tickler://view/today)
        """)
    }

    @Test func nothingToSayIsNil() {
        #expect(digest([]) == nil)
        #expect(digest([reminder("later1", due: "2026-10-03 09:00")]) == nil)
        #expect(digest([reminder("later2", due: "2026-10-03 09:00", cwd: "/work/other")]) == nil)
    }

    @Test func capsAtEightLines() throws {
        let many = (0 ..< 11).map { reminder(String(format: "late%02d", $0), due: "2026-09-30 16:00") }
        let text = try #require(digest(many))
        let lines = text.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("- overdue since") }.count == 8)
        #expect(lines.last == "- and 3 more: [open today in Tickler](tickler://view/today)")
    }

    @Test func titlesAreOneShortLine() throws {
        let long = String(repeating: "a", count: 300)
        let text = try #require(digest([
            reminder("late01", "first\nsecond", due: "2026-09-30 16:00"),
            reminder("late02", long, due: "2026-09-30 16:01"),
        ]))
        #expect(text.contains("[first second](tickler://open/late01)"))
        #expect(text.contains("[" + String(repeating: "a", count: 99) + "…](tickler://open/late02)"))
    }

    @Test func matchingOutsideGitUsesTheFolderTree() throws {
        let inside = reminder("late01", due: "2026-09-30 16:00", cwd: "/tmp/scratch/sub")
        let outside = reminder("late02", due: "2026-09-30 16:00", cwd: "/tmp/elsewhere")
        let text = try #require(digest([inside, outside], folder: "/tmp/scratch"))
        #expect(text.contains("Tickler reminders for scratch"))
        #expect(text.contains("(tickler://open/late01)"))
        #expect(text.contains("Other projects: 1 overdue."))
    }

    @Test func aMissingFolderIsNotAttached() throws {
        let gone = reminder("late01", due: "2026-09-30 16:00", cwd: "/tmp/scratch/gone")
        let text = try #require(SessionDigest.text(
            reminders: [gone], sessionFolder: "/tmp/scratch", now: Fixture.now, calendar: Fixture.calendar,
            gitRoot: { _ in nil }, folderExists: { $0 != "/tmp/scratch/gone" }
        ))
        #expect(text.hasPrefix("Tickler (information only"))
    }

    @Test func aFutureReminderNeverCallsGit() {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        _ = SessionDigest.text(
            reminders: [
                reminder("next01", due: "2026-10-08 09:00", cwd: "/work/platform/next"),
                reminder("late01", due: "2026-09-30 16:00"),
            ],
            sessionFolder: "/work/platform", now: Fixture.now, calendar: Fixture.calendar,
            gitRoot: { folder in calls.withLock { $0.append(folder) }
                return folder.hasPrefix("/work/platform") ? "/work/platform" : nil
            },
            folderExists: { _ in true }
        )
        #expect(calls.withLock { $0 }.contains("/work/platform/next") == false)
    }

    @Test func aFiredReminderDueNowIsListedOnce() throws {
        let text = try #require(digest([reminder("fire01", due: "2026-10-01 10:45", trigger: "approved", fired: "MR !1 merged")]))
        #expect(text.components(separatedBy: "tickler://open/fire01").count == 2)
    }

    @Test func textsAreSanitized() throws {
        let nasty = "a\u{1B}[31m\u{202E}b\u{200B}c x [docs](https://evil)"
        let text = try #require(digest([
            reminder("late01", nasty, due: "2026-09-30 16:00"),
            reminder("wait01", "w", due: "2026-10-06 09:30", trigger: "ok\n[x](y)"),
            reminder("fire01", "f", due: "2026-10-01 10:40", fired: "why\nsecond [l](u)"),
        ]))
        #expect(!text.contains("](h") && !text.contains("](y") && !text.contains("](u"))
        #expect(text.components(separatedBy: "](").count == 4)
        #expect(text.unicodeScalars.allSatisfy { $0.properties.generalCategory != .format && ($0 == "\n" || $0.value >= 0x20) })
        #expect(text.contains("[a(31mbc x (docs)(https://evil)](tickler://open/late01)"))
        #expect(text.contains("waiting for ok (x)(y), deadline"))
        #expect(text.contains("fired (why second (l)(u)): [f]"))
    }

    @Test func budgetStopsSpawningGit() {
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let lookup = GitRoot.budgeted(total: 5, clock: { now.withLock { $0 } }, lookup: { _ in
            calls.withLock { $0 += 1 }
            return "/r"
        })
        #expect(lookup("/a") == "/r")
        now.withLock { $0 = Date(timeIntervalSince1970: 4.9) }
        #expect(lookup("/b") == "/r")
        now.withLock { $0 = Date(timeIntervalSince1970: 5) }
        #expect(lookup("/c") == nil)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func countsRemindersDueWithinTheHourElsewhere() throws {
        let text = try #require(digest([
            reminder("soon01", due: "2026-10-01 11:30", cwd: "/work/other"),
            reminder("late01", due: "2026-09-30 16:00", cwd: "/work/other"),
            reminder("later1", due: "2026-10-01 12:00", cwd: "/work/other"),
        ]))
        #expect(text.hasSuffix("Other projects: 1 overdue, 1 due within the hour. [open today in Tickler](tickler://view/today)"))
    }

    @Test func summaryCountsSectionsForTheTerminal() throws {
        let digest = try #require(SessionDigest.digest(
            reminders: [
                reminder("late01", due: "2026-09-30 16:00"),
                reminder("today1", due: "2026-10-01 17:30"),
                reminder("today2", due: "2026-10-01 18:00"),
                reminder("other1", due: "2026-09-29 09:00", cwd: "/work/other"),
            ],
            sessionFolder: "/work/platform", now: Fixture.now, calendar: Fixture.calendar,
            gitRoot: roots, folderExists: { _ in true }
        ))
        #expect(digest.summary == "Tickler: 1 overdue, 2 today in platform; 1 overdue elsewhere")
    }
}
