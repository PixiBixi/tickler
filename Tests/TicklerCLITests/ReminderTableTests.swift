import Foundation
import Testing
@testable import TicklerCLI
@testable import TicklerCore

struct ReminderTableTests {
    func reminder(_ id: String, _ title: String, at due: String, project: String? = nil, status: Reminder.Status = .open) -> Reminder {
        let date = StrictDate.parse(due, calendar: CLIHarness.calendar)!
        return Reminder(
            id: id, title: title, notes: "", dueAt: date, originalDueAt: date, rescheduleCount: 0, status: status,
            sessionId: nil, cwd: project.map { "/src/\($0)" }, source: .claude, externalRef: nil, notifiedAt: nil,
            doneAt: nil, createdAt: date, updatedAt: date
        )
    }

    @Test func groupsAlignsAndTruncates() {
        let table = ReminderTable(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 60, color: false)
        let output = table.render([
            reminder("late01", "Merge the MR", at: "2026-10-01 09:30", project: "prober"),
            reminder("soon01", "A very long title that will not fit in a sixty column terminal at all", at: "2026-10-01 11:00"),
            reminder("next01", "Check Tempo", at: "2026-10-02 09:30", project: "prober"),
        ])
        let lines = output.components(separatedBy: "\n")
        #expect(lines[0] == "Overdue (1)")
        #expect(lines[1].hasPrefix("late01  09:30  Merge the MR"))
        #expect(lines[1].hasSuffix("prober"))
        #expect(lines.contains("Today (1)"))
        #expect(lines.contains("Tomorrow (1)"))
        #expect(output.contains("…"))
        #expect(lines.allSatisfy { $0.count <= 60 })
    }

    @Test func colorAddsLinksToTheApp() {
        let table = ReminderTable(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 80, color: true)
        let output = table.render([reminder("abc234", "t", at: "2026-10-02 09:30")])
        #expect(output.contains("\u{1B}]8;;tickler://open/abc234\u{1B}\\"))
    }

    @Test func pipesKeepThePlainLines() {
        let cli = CLIHarness()
        _ = cli.run("add", "plain", "--at", "2026-10-01 12:00")
        #expect(!cli.run("list").out.contains("\u{1B}"))
    }
}

struct ReminderCardTests {
    @Test func rendersMarkdownLinksAndTheResumeCommand() throws {
        let date = try #require(StrictDate.parse("2026-10-01 11:00", calendar: CLIHarness.calendar))
        let reminder = Reminder(
            id: "abc234", title: "Check the dashboard",
            notes: "1) Run `glab mr view 221` **first**\nSee https://acme.atlassian.net/browse/OPS-1",
            dueAt: date, originalDueAt: date, rescheduleCount: 0, status: .open, sessionId: "5b26f281-1806-47aa-8842-0e264f7b9d35",
            cwd: "/src/platform", source: .claude, externalRef: nil, notifiedAt: nil, doneAt: nil, createdAt: date, updatedAt: date
        )
        let card = ReminderCard(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 100, sessionRunning: false)
        let output = card.render(reminder, links: LinkExtractor.links(reminderId: "abc234", notes: reminder.notes, explicit: []))
        #expect(output.contains("\u{1B}[36mglab mr view 221\u{1B}[0m"))
        #expect(output.contains("\u{1B}[1mfirst\u{1B}[0m"))
        #expect(output.contains("\u{1B}]8;;https://acme.atlassian.net/browse/OPS-1\u{1B}\\"))
        #expect(output.contains("tickler resume abc234"))
        #expect(!output.contains("**"))
    }
}
