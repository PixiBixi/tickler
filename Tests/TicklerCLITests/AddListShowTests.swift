import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct AddListShowTests {
    @Test func addThenListJSONHasTheDocumentedShape() throws {
        let cli = CLIHarness()
        let added = cli.run(
            "add", "Check the dashboard", "--at", "2026-10-01 14:30", "--notes", "See https://acme.atlassian.net/browse/OPS-2204",
            "--link", "https://gitlab.example.com/g/p/-/merge_requests/221", "--session", "6e077b7d-ca93-41cd-9fe9-c2af0815fc60",
            "--cwd", "/work/git/x", "--json"
        )
        #expect(added.code == 0)
        let id = try #require(added.jsonObject()["id"] as? String)

        let list = try cli.run("list", "--json").jsonArray()
        #expect(list.count == 1)
        let item = try #require(list.first)
        #expect(item["id"] as? String == id)
        #expect(item["due"] as? String == "2026-10-01 14:30")
        #expect(item["dueISO"] as? String == "2026-10-01T14:30:00+02:00")
        #expect(item["originalDue"] as? String == "2026-10-01 14:30")
        #expect(item["rescheduleCount"] as? Int == 0)
        #expect(item["status"] as? String == "open")
        #expect(item["source"] as? String == "claude")
        #expect(item["sessionId"] as? String == "6e077b7d-ca93-41cd-9fe9-c2af0815fc60")
        #expect(item["project"] as? String == "x")
        #expect(item["overdue"] as? Bool == false)
        let links = try #require(item["links"] as? [[String: String]])
        #expect(links.map { $0["kind"] } == ["jira", "gitlabMR"])
        #expect(links.allSatisfy { $0["label"] != nil && $0["url"] != nil })
    }

    @Test func jsonKeysAreSortedAndNullsAreWritten() {
        let cli = CLIHarness()
        let out = cli.run("add", "Plain", "--at", "2026-10-02 09:00", "--json").out
        #expect(out.contains("\"sessionId\" : null"))
        let cwdIndex = out.range(of: "\"cwd\"")?.lowerBound
        let dueIndex = out.range(of: "\"due\"")?.lowerBound
        #expect(cwdIndex != nil && dueIndex != nil && cwdIndex! < dueIndex!)
    }

    @Test func addPrintsTabSeparatedSummary() {
        let cli = CLIHarness()
        let result = cli.run("add", "Call back", "--at", "2026-10-02 09:00")
        let fields = result.out.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        #expect(fields.count == 3)
        #expect(fields[0].count == 6)
        #expect(fields[1] == "Call back")
        #expect(fields[2] == "2026-10-02 09:00")
    }

    @Test func sessionAndCwdDefaultFromTheEnvironment() throws {
        var cli = CLIHarness()
        cli.environment = ["CLAUDE_CODE_SESSION_ID": "6e077b7d-ca93-41cd-9fe9-c2af0815fc60"]
        let object = try cli.run("add", "From Claude", "--at", "2026-10-02 09:00", "--json").jsonObject()
        #expect(object["sessionId"] as? String == "6e077b7d-ca93-41cd-9fe9-c2af0815fc60")
        #expect(object["cwd"] as? String == "/work/current")
        #expect(object["source"] as? String == "claude")
    }

    @Test func humanWithoutSessionGetsNoCwd() throws {
        let cli = CLIHarness()
        let object = try cli.run("add", "By hand", "--at", "2026-10-02 09:00", "--json").jsonObject()
        #expect(object["sessionId"] is NSNull)
        #expect(object["cwd"] is NSNull)
        #expect(object["source"] as? String == "human")
    }

    @Test func notesDashReadsStdin() throws {
        var cli = CLIHarness()
        cli.stdin = "from stdin\nsecond line\n"
        let object = try cli.run("add", "Piped", "--at", "2026-10-02 09:00", "--notes", "-", "--json").jsonObject()
        #expect(object["notes"] as? String == "from stdin\nsecond line")
    }

    @Test func listIsEmptyAndQuietWhenNothingIsDue() {
        let result = CLIHarness().run("list")
        #expect(result.code == 0)
        #expect(result.out.isEmpty)
    }

    @Test func listHumanLineAndFilters() throws {
        let cli = CLIHarness()
        _ = cli.run("add", "Today thing", "--at", "2026-10-01 16:00", "--cwd", "/work/git/alpha")
        _ = cli.run("add", "Next week thing", "--at", "2026-10-20 09:00", "--cwd", "/work/git/beta")
        let today = cli.run("list").out.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        #expect(today.count == 1)
        #expect(today[0].hasSuffix("  2026-10-01 16:00  Today thing  [alpha]"))
        #expect(try cli.run("list", "--due", "all", "--json").jsonArray().count == 2)
        #expect(try cli.run("list", "--due", "all", "--project", "beta", "--json").jsonArray().count == 1)
    }

    @Test func overdueReminderIsMarked() throws {
        let cli = CLIHarness()
        let store = try cli.store()
        try store.add(ReminderDraft(title: "Late", dueAt: CLIHarness.now.addingTimeInterval(-3600), source: .human))
        #expect(cli.run("list").out.contains("Late  OVERDUE"))
        let item = try #require(cli.run("list", "--json").jsonArray().first)
        #expect(item["overdue"] as? Bool == true)
    }

    @Test func showPrintsDetailsAndResumeCommand() throws {
        let cli = CLIHarness()
        let id = try #require(
            cli.run(
                "add", "Detail", "--at", "2026-10-02 09:00", "--notes", "https://grafana.example.com/d/abc", "--session",
                "6e077b7d-ca93-41cd-9fe9-c2af0815fc60", "--cwd", "/work/git/x", "--json"
            ).jsonObject()["id"] as? String
        )
        let out = cli.run("show", id).out
        #expect(out.contains("title: Detail"))
        #expect(out.contains("session: 6e077b7d-ca93-41cd-9fe9-c2af0815fc60"))
        #expect(out.contains("cwd: /work/git/x"))
        #expect(out.contains("  grafana abc https://grafana.example.com/d/abc"))
        #expect(out.contains("resume: tickler resume \(id)"))
    }

    @Test func badDateExitsWithUsageError() {
        let cli = CLIHarness()
        for value in ["tomorrow 9h", "2026-02-31 10:00", "2026-10-01 09:00"] {
            let result = cli.run("add", "x", "--at", value)
            #expect(result.code == 2, "\(value)")
            #expect(result.err.hasPrefix("error: "))
        }
    }

    @Test func missingOptionAndBadEnumExitWithUsageError() {
        let cli = CLIHarness()
        #expect(cli.run("add", "no date").code == 2)
        #expect(cli.run("list", "--due", "someday").code == 2)
    }

    @Test func unknownIdExitsWithThree() {
        let cli = CLIHarness()
        let result = cli.run("show", "zzzzzz")
        #expect(result.code == 3)
        #expect(result.err == "error: no reminder with id zzzzzz\n")
    }
}
