import Foundation
import Testing
@testable import TicklerCLI

struct MutationTests {
    private func addReminder(_ cli: CLIHarness, at due: String = "2026-10-01 16:00") throws -> String {
        try #require(cli.run("add", "Thing", "--at", due, "--json").jsonObject()["id"] as? String)
    }

    @Test func doneRemovesFromDefaultListAndShowsInDone() throws {
        let cli = CLIHarness()
        let id = try addReminder(cli)
        #expect(cli.run("done", id).code == 0)
        #expect(cli.run("list").out.isEmpty)
        #expect(try cli.run("list", "--status", "done", "--json").jsonArray().map { $0["id"] as? String } == [id])
    }

    @Test func snoozeForCountsFromNow() throws {
        let cli = CLIHarness()
        let id = try addReminder(cli)
        let object = try cli.run("snooze", id, "--for", "1h", "--json").jsonObject()
        #expect(object["due"] as? String == "2026-10-01 11:45")
        #expect(object["rescheduleCount"] as? Int == 1)
        #expect(object["originalDue"] as? String == "2026-10-01 16:00")
        let days = try cli.run("snooze", id, "--for", "2d", "--json").jsonObject()
        #expect(days["due"] as? String == "2026-10-03 10:45")
    }

    @Test func snoozeToSetsTheDate() throws {
        let cli = CLIHarness()
        let id = try addReminder(cli)
        let object = try cli.run("snooze", id, "--to", "2026-10-05 08:15", "--json").jsonObject()
        #expect(object["due"] as? String == "2026-10-05 08:15")
    }

    @Test func snoozeRejectsBadInput() throws {
        let cli = CLIHarness()
        let id = try addReminder(cli)
        #expect(cli.run("snooze", id).code == 2)
        #expect(cli.run("snooze", id, "--for", "1h", "--to", "2026-10-05 08:15").code == 2)
        #expect(cli.run("snooze", id, "--for", "soon").code == 2)
        #expect(cli.run("snooze", id, "--for", "0m").code == 2)
        #expect(cli.run("snooze", id, "--to", "2026-09-30 08:15").code == 2)
    }

    @Test func editAtBumpsRescheduleCountButTitleDoesNot() throws {
        let cli = CLIHarness()
        let id = try addReminder(cli)
        let renamed = try cli.run("edit", id, "--title", "Renamed", "--json").jsonObject()
        #expect(renamed["title"] as? String == "Renamed")
        #expect(renamed["rescheduleCount"] as? Int == 0)
        let moved = try cli.run("edit", id, "--at", "2026-10-02 09:30", "--json").jsonObject()
        #expect(moved["due"] as? String == "2026-10-02 09:30")
        #expect(moved["rescheduleCount"] as? Int == 1)
    }

    @Test func editNotesFromStdinRebuildsLinks() throws {
        var cli = CLIHarness()
        let id = try addReminder(cli)
        cli.stdin = "see https://acme.atlassian.net/browse/OPS-1\n"
        let object = try cli.run("edit", id, "--notes", "-", "--json").jsonObject()
        #expect(object["notes"] as? String == "see https://acme.atlassian.net/browse/OPS-1")
        #expect((object["links"] as? [[String: String]])?.first?["label"] == "OPS-1")
    }

    @Test func editWithoutChangesIsUsageError() throws {
        let cli = CLIHarness()
        #expect(try cli.run("edit", addReminder(cli)).code == 2)
    }

    @Test func rmHidesTheReminder() throws {
        let cli = CLIHarness()
        let id = try addReminder(cli)
        #expect(cli.run("rm", id).code == 0)
        #expect(cli.run("list", "--due", "all").out.isEmpty)
        #expect(cli.run("show", id).code == 3)
        #expect(cli.run("rm", id).code == 3)
    }

    @Test func unknownIdExitsWithThreeEverywhere() {
        let cli = CLIHarness()
        #expect(cli.run("done", "zzzzzz").code == 3)
        #expect(cli.run("snooze", "zzzzzz", "--for", "1h").code == 3)
        #expect(cli.run("edit", "zzzzzz", "--title", "x").code == 3)
        #expect(cli.run("rm", "zzzzzz").code == 3)
    }

    @Test(arguments: [("15m", 900.0), ("1h", 3600.0), ("2d", 172_800.0), ("90m", 5400.0)])
    func parsesDurations(value: String, seconds: Double) {
        #expect(SnoozeDuration.parse(value) == seconds)
    }

    @Test(arguments: ["", "0m", "-5m", "1.5h", "1w", "h", "1 h", "m15"])
    func rejectsBadDurations(value: String) {
        #expect(SnoozeDuration.parse(value) == nil)
    }
}
