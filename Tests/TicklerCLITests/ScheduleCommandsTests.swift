import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct ScheduleCommandsTests {
    private func freshHarness(busy: [DateInterval] = []) throws -> CLIHarness {
        let cli = CLIHarness()
        try cli.store().replaceBusy(busy, at: CLIHarness.now)
        return cli
    }

    @Test func overflowingDurationIsAUsageError() {
        let result = CLIHarness().run("slot", "--duration", "999999999999999999h")
        #expect(result.code == 2)
        #expect(result.err.contains("--duration expects"))
    }

    @Test func unplacedReminderKeepsItsTimeAndLogsNothing() throws {
        let cli = try freshHarness()
        #expect(cli.run("add", "Long", "--at", "2026-10-03 11:00", "--duration", "1h").code == 0)
        let before = try #require(cli.store().list(ReminderFilter(due: .all, status: .open)).first)
        #expect(cli.run("config", "set", "working-hours", "08:00-08:30").code == 0)
        #expect(try cli.store().require(before.id).dueAt == before.dueAt)
        #expect(try cli.store().moves(since: .distantPast, includeMigration: true).isEmpty)
    }

    @Test func configShowsDefaults() {
        let result = CLIHarness().run("config")
        #expect(result.code == 0)
        #expect(result.out.contains("working-days mon-fri"))
        #expect(result.out.contains("working-hours 09:30-19:30"))
        #expect(result.out.contains("default-duration 15m"))
        #expect(result.out.contains("lunch off"))
        #expect(result.out.contains("busy-calendars 0 chosen in Tickler.app"))
    }

    @Test func configSchedulingDefaultsToAutoOnTheFirstLine() {
        let result = CLIHarness().run("config")
        #expect(result.out.hasPrefix("scheduling auto\n"))
    }

    @Test func configSetSchedulingPersistsAndValidates() throws {
        let cli = CLIHarness()
        #expect(cli.run("config", "set", "scheduling", "place-only").code == 0)
        #expect(cli.run("config").out.hasPrefix("scheduling place-only\n"))
        #expect(try cli.run("config", "--json").jsonObject()["scheduling"] as? String == "place-only")
        #expect(try cli.store().schedule().mode == .placeOnly)
        let bad = cli.run("config", "set", "scheduling", "manual")
        #expect(bad.code == 2)
        #expect(bad.err.contains("auto, place-only, off"))
    }

    @Test func configSetValidatesAndPersists() throws {
        let cli = CLIHarness()
        let bad = cli.run("config", "set", "working-days", "")
        #expect(bad.code == 2)
        #expect(bad.err.contains("working-days expects"))
        #expect(cli.run("config", "set", "default-duration", "30m").code == 0)
        #expect(cli.run("config").out.contains("default-duration 30m"))
        #expect(try cli.run("config", "--json").jsonObject()["default-duration"] as? String == "30m")
        #expect(cli.run("config", "set", "lunch", "45m@12:00-14:00").code == 0)
        #expect(cli.run("config").out.contains("lunch 45m@12:00-14:00"))
    }

    @Test func configRefusesBusyCalendars() {
        let result = CLIHarness().run("config", "set", "busy-calendars", "x")
        #expect(result.code == 2)
        #expect(result.err.contains("choose busy calendars in Tickler.app Settings"))
    }

    @Test func configSetReplansAndReports() throws {
        let cli = try freshHarness()
        _ = cli.run("add", "Later", "--at", "2026-10-01 18:00")
        let result = cli.run("config", "set", "working-hours", "09:30-12:00")
        #expect(result.code == 0)
        #expect(result.out.contains("Moved: Later to Fri 2 Oct 09:30 (day full)"))
    }

    @Test func slotChangesNothing() throws {
        let cli = try freshHarness()
        let result = cli.run("slot", "--duration", "30m")
        #expect(result.out.contains("Thu 1 Oct 10:45-11:15"))
        #expect(try cli.store().list(ReminderFilter(due: .all)).isEmpty)
    }

    @Test func slotOnDay() throws {
        let result = try freshHarness().run("slot", "--day", "2026-10-05")
        #expect(result.out.contains("Mon 5 Oct 09:30-09:45"))
    }

    @Test func slotWithoutCopyWarnsAndWritesNoFlag() throws {
        let cli = CLIHarness()
        let result = cli.run("slot")
        #expect(result.code == 0)
        #expect(result.err.contains("no recent calendar copy"))
        #expect(try !cli.store().isScheduleMigrated())
    }

    @Test func planShowsBusyWithoutTitles() throws {
        let busy = try DateInterval(
            start: #require(StrictDate.parse("2026-10-01 11:00", calendar: CLIHarness.calendar)),
            end: #require(StrictDate.parse("2026-10-01 11:30", calendar: CLIHarness.calendar))
        )
        let cli = try freshHarness(busy: [busy])
        _ = cli.run("add", "Review MR !412", "--at", "2026-10-01 11:30")
        _ = cli.run("add", "Deploy check", "--at", "2026-10-01 11:45", "--fixed")
        let lines = cli.run("plan", "2026-10-01").out.split(separator: "\n").map(String.init)
        #expect(lines.contains("11:00-11:30 busy"))
        #expect(lines.contains("11:30-11:45 Review MR !412"))
        #expect(lines.contains("11:45-12:00 Deploy check (fixed)"))
        #expect(lines.contains("12:00-19:30 free"))
        #expect(lines.first == "09:30-11:00 free")
    }

    @Test func planDefaultsToTodayAndJson() throws {
        let cli = try freshHarness()
        #expect(try cli.run("plan", "--json").jsonArray().first?["kind"] as? String == "free")
        #expect(cli.run("plan", "nope").code == 2)
    }
}
