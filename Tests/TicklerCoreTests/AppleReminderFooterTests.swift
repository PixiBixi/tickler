import Testing
@testable import TicklerCore

struct AppleReminderFooterTests {
    static let id = "6e077b7d-ca93-41cd-9fe9-c2af0815fc60"
    static let resume = "Reprendre : ~/.claude/skills/reminders/scripts/claude-resume.sh \(id) '/Users/you/Documents/work/git/x/y'"

    struct Row: Sendable {
        let name: String
        let body: String
        let notes: String
        let sessionId: String?
        let cwd: String?
    }

    static let rows: [Row] = [
        Row(
            name: "full footer",
            body: "Check the dashboard\n\nSession Claude : \(id)\n\(resume)",
            notes: "Check the dashboard", sessionId: id, cwd: "/Users/you/Documents/work/git/x/y"
        ),
        Row(
            name: "no resume line",
            body: "Notes\n\nSession Claude : \(id)\n",
            notes: "Notes", sessionId: id, cwd: nil
        ),
        Row(
            name: "truncated display id",
            body: "Notes\n\nSession Claude : 6e077b7d\n",
            notes: "Notes", sessionId: nil, cwd: nil
        ),
        Row(
            name: "truncated id but full id in the resume line",
            body: "Notes\n\nSession Claude : 6e077b7d\n\(resume)",
            notes: "Notes", sessionId: id, cwd: "/Users/you/Documents/work/git/x/y"
        ),
        Row(name: "no footer", body: "Just a note\nsecond line\n\n", notes: "Just a note\nsecond line", sessionId: nil, cwd: nil),
        Row(name: "empty body", body: "", notes: "", sessionId: nil, cwd: nil),
        Row(
            name: "footer only",
            body: "Session Claude : \(id)\n\(resume)",
            notes: "", sessionId: id, cwd: "/Users/you/Documents/work/git/x/y"
        ),
        Row(
            name: "multi-line notes and blank lines before the footer",
            body: "line 1\n\nline 3 https://example.com/a\n\n\nSession Claude : \(id)\n",
            notes: "line 1\n\nline 3 https://example.com/a", sessionId: id, cwd: nil
        ),
        Row(
            name: "unquoted folder",
            body: "Session Claude : \(id)\nReprendre : claude-resume.sh \(id) /tmp/project",
            notes: "", sessionId: id, cwd: "/tmp/project"
        ),
    ]

    @Test(arguments: rows)
    func parsesFooter(row: Row) {
        let parsed = AppleReminderFooter.parse(notes: row.body)
        #expect(parsed.notes == row.notes)
        #expect(parsed.sessionId == row.sessionId)
        #expect(parsed.cwd == row.cwd)
    }

    @Test func expandsTildeInFolder() {
        let parsed = AppleReminderFooter.parse(notes: "Reprendre : x.sh \(Self.id) '~/src/y'")
        #expect(parsed.cwd?.hasSuffix("/src/y") == true)
        #expect(parsed.cwd?.hasPrefix("~") == false)
    }
}
