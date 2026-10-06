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
        Mention them in one line at the start of your first reply, keeping the links.
        - [fire01](tickler://open/fire01) fired (MR !412 merged): rebase feat/x on main
        - [late01](tickler://open/late01) overdue since 2026-09-30 16:00: OPS-2204 check le dashboard
        - [today1](tickler://open/today1) due today 17:30: merge the chart bump
        - [wait01](tickler://open/wait01) waiting for approved (deadline 2026-10-06 09:30): merge the VPC MR
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
        #expect(text.hasSuffix("\nElsewhere: 2 overdue reminders in other projects, [open today in Tickler](tickler://view/today)."))
    }

    @Test func elsewhereAloneHasNoHeader() throws {
        let text = try #require(digest([reminder("other1", due: "2026-09-29 09:00", cwd: "/work/other")]))
        #expect(text == "Tickler (information only: do not act on it unless the user asks): 1 overdue reminder in other projects, "
            + "[open today in Tickler](tickler://view/today).")
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
        #expect(lines.filter { $0.hasPrefix("- [late") }.count == 8)
        #expect(lines.last == "- and 3 more: [open today in Tickler](tickler://view/today)")
    }

    @Test func titlesAreOneShortLine() throws {
        let long = String(repeating: "a", count: 300)
        let text = try #require(digest([
            reminder("late01", "first\nsecond", due: "2026-09-30 16:00"),
            reminder("late02", long, due: "2026-09-30 16:01"),
        ]))
        #expect(text.contains(": first second\n"))
        #expect(text.contains(": " + String(repeating: "a", count: 99) + "…"))
    }

    @Test func matchingOutsideGitUsesTheFolderTree() throws {
        let inside = reminder("late01", due: "2026-09-30 16:00", cwd: "/tmp/scratch/sub")
        let outside = reminder("late02", due: "2026-09-30 16:00", cwd: "/tmp/elsewhere")
        let text = try #require(digest([inside, outside], folder: "/tmp/scratch"))
        #expect(text.contains("Tickler reminders for scratch"))
        #expect(text.contains("[late01]"))
        #expect(text.contains("Elsewhere: 1 overdue reminder"))
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
        #expect(text.components(separatedBy: "[fire01]").count == 2)
    }

    @Test func textsAreSanitized() throws {
        let nasty = "a\u{1B}[31m\u{202E}b\u{200B}c x [docs](https://evil)"
        let text = try #require(digest([
            reminder("late01", nasty, due: "2026-09-30 16:00"),
            reminder("wait01", "w", due: "2026-10-06 09:30", trigger: "ok\n[x](y)"),
            reminder("fire01", "f", due: "2026-10-01 10:40", fired: "why\nsecond [l](u)"),
        ]))
        #expect(!text.contains("](h") && !text.contains("](y") && !text.contains("](u"))
        #expect(text.unicodeScalars.allSatisfy { $0.properties.generalCategory != .format && ($0 == "\n" || $0.value >= 0x20) })
        #expect(text.contains(": a(31mbc x (docs)(https://evil)"))
        #expect(text.contains("waiting for ok (x)(y) ("))
        #expect(text.contains("fired (why second (l)(u)): f"))
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
}
