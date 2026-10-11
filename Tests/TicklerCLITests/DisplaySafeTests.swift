import Foundation
import Testing
@testable import TicklerCLI
@testable import TicklerCore

struct DisplaySafeTests {
    static let hostile = "Merge\u{1B}[2J\u{1B}]0;pwned\u{7}\nnext\u{9B}31m"

    @Test func controlCharactersBecomeAVisiblePlaceholder() {
        #expect("a\u{1B}[0mb\u{7}\u{9B}c\u{7F}".displaySafe == "a\u{FFFD}[0mb\u{FFFD}\u{FFFD}c\u{FFFD}")
        #expect("keep\ttab\nand newline".displaySafe == "keep\ttab\nand newline")
        #expect("plain text, accents é and emoji 🙂".displaySafe == "plain text, accents é and emoji 🙂")
    }

    @Test func singleLineFieldsCollapseBreaksIntoSpaces() {
        #expect("a\nb\r\nc\td".displaySafeLine == "a b c d")
        #expect("x\u{1B}y\nz".displaySafeLine == "x\u{FFFD}y z")
    }

    @Test func listAndShowStayOnTheirLinesWithoutEscapes() throws {
        let cli = CLIHarness()
        #expect(cli.run("add", Self.hostile, "--at", "2026-10-02 09:00", "--notes", "n\u{1B}[31mred\nline2").code == 0)

        let list = cli.run("list", "--due", "all").out
        #expect(!list.contains("\u{1B}"))
        #expect(list.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)

        let id = try #require(cli.run("list", "--due", "all", "--json").jsonArray().first?["id"] as? String)
        let show = cli.run("show", id).out
        #expect(!show.contains("\u{1B}"))
        #expect(!show.contains("\u{9B}"))
        #expect(show.contains("title: Merge\u{FFFD}[2J\u{FFFD}]0;pwned\u{FFFD} next\u{FFFD}31m"))
        #expect(show.contains("  n\u{FFFD}[31mred\n  line2"))
    }

    @Test func tableAndCardEscapeStoredText() throws {
        let date = try #require(StrictDate.parse("2026-10-02 09:00", calendar: CLIHarness.calendar))
        let reminder = Reminder(
            id: "abc234", title: Self.hostile, notes: "see \u{1B}[31m[x\u{1B}](https://a.io)", dueAt: date, originalDueAt: date,
            rescheduleCount: 0, status: .open, sessionId: nil, cwd: "/src/p\u{1B}x", source: .claude, externalRef: nil,
            notifiedAt: nil, doneAt: nil, createdAt: date, updatedAt: date
        )
        let table = ReminderTable(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 80, color: false)
        let rows = table.render([reminder]).components(separatedBy: "\n")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.contains("\u{1B}") })

        let link = ReminderLink(reminderId: "abc234", position: 0, url: "https://a.io", kind: .other, label: "lab\u{1B}el\nx")
        let card = ReminderCard(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 100, sessionRunning: nil)
        let output = card.render(reminder, links: [link])
        let withoutOwnEscapes = output.replacing(/\u{1B}\[[0-9;]*m|\u{1B}\]8;;[^\u{1B}]*\u{1B}\\/, with: "")
        #expect(!withoutOwnEscapes.contains("\u{1B}"))
        #expect(output.contains("lab\u{FFFD}el x"))
    }

    @Test func jsonOutputKeepsTheStoredTextUntouched() throws {
        let cli = CLIHarness()
        let added = cli.run("add", Self.hostile, "--at", "2026-10-02 09:00", "--json")
        #expect(added.code == 0)
        #expect(try added.jsonObject()["title"] as? String == Self.hostile)
        #expect(added.out.contains("\\u001b"))
        let listed = try cli.run("list", "--due", "all", "--json").jsonArray()
        #expect(listed.first?["title"] as? String == Self.hostile)
    }
}
