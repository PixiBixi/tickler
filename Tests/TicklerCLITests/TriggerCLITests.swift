import Foundation
import Testing
@testable import TicklerCLI

struct TriggerCLITests {
    let mr = "https://gitlab.com/acme/app/-/merge_requests/412"

    @Test func addWithWhenAndNoDateUsesTheDefaultDeadline() throws {
        let object = try CLIHarness().run("add", "rebase", "--link", mr, "--when", "merged", "--json").jsonObject()
        #expect(object["trigger"] as? String == "merged")
        #expect(object["waiting"] as? Bool == true)
        #expect(object["due"] as? String == "2026-10-06 09:30")
        #expect(object["firedAt"] is NSNull)
        #expect(object["firedReason"] is NSNull)
    }

    @Test func addWithWhenAndAt() throws {
        let object = try CLIHarness().run("add", "rebase", "--link", mr, "--when", "approved", "--at", "2026-10-08 10:00", "--json")
            .jsonObject()
        #expect(object["due"] as? String == "2026-10-08 10:00")
        #expect(object["trigger"] as? String == "approved")
    }

    @Test func aTriggerFoundInTheNotesLinkIsAccepted() {
        #expect(CLIHarness().run("add", "rebase", "--notes", "see \(mr)", "--when", "merged").code == 0)
    }

    @Test func addRefusesBadTriggers() {
        let cli = CLIHarness()
        #expect(cli.run("add", "rebase").code == 2)
        #expect(cli.run("add", "rebase", "--link", mr, "--when", "soon").code == 2)
        let unsupported = cli.run("add", "rebase", "--link", mr, "--when", "jira:done")
        #expect(unsupported.code == 2)
        #expect(unsupported.err.contains("jira:done"))
        #expect(cli.run("add", "rebase", "--when", "merged").code == 2)
    }

    @Test func plainReminderJSONHasNullTrigger() throws {
        let object = try CLIHarness().run("add", "Thing", "--at", "2026-10-01 16:00", "--json").jsonObject()
        #expect(object["trigger"] is NSNull)
        #expect(object["waiting"] as? Bool == false)
    }

    @Test func editSetsReplacesAndRemovesTheTrigger() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "rebase", "--link", mr, "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        #expect(try cli.run("edit", id, "--when", "pipeline-green", "--json").jsonObject()["trigger"] as? String == "pipeline-green")
        #expect(cli.run("edit", id, "--when", "jira:done").code == 2)
        let cleared = try cli.run("edit", id, "--when", "", "--json").jsonObject()
        #expect(cleared["trigger"] is NSNull)
        #expect(cleared["waiting"] as? Bool == false)
    }

    @Test func editAtKeepsTheReminderWaiting() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "rebase", "--link", mr, "--when", "merged", "--json").jsonObject()["id"] as? String)
        let moved = try cli.run("edit", id, "--at", "2026-10-09 09:30", "--json").jsonObject()
        #expect(moved["due"] as? String == "2026-10-09 09:30")
        #expect(moved["trigger"] as? String == "merged")
    }

    @Test func listWaitingShowsOnlyWaitingRemindersAtAnyDate() throws {
        let cli = CLIHarness()
        _ = cli.run("add", "plain", "--at", "2026-10-01 16:00")
        let id = try #require(cli.run("add", "rebase", "--link", mr, "--when", "merged", "--json").jsonObject()["id"] as? String)
        #expect(try cli.run("list", "--waiting", "--json").jsonArray().map { $0["id"] as? String } == [id])
        #expect(try cli.run("list", "--json").jsonArray().count == 1)
    }

    @Test func tableShowsAWaitingGroup() throws {
        let cli = CLIHarness()
        _ = cli.run("add", "rebase", "--link", mr, "--when", "merged")
        let table = try ReminderTable(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 100, color: false)
            .render(cli.store().list(.init(due: .all)))
        #expect(table.contains("Waiting (1)"))
        #expect(!table.contains("Later"))
    }
}
