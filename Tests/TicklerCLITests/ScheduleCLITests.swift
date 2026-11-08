import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct ScheduleCLITests {
    /// A busy copy stamped now, so the CLI plans the whole day like the app.
    private func freshHarness(busy: [DateInterval] = []) throws -> CLIHarness {
        let cli = CLIHarness()
        try cli.store().replaceBusy(busy, at: CLIHarness.now)
        return cli
    }

    @Test func addWithoutAtTakesFirstSlot() throws {
        let cli = try freshHarness()
        let result = cli.run("add", "T")
        #expect(result.code == 0)
        #expect(result.out.contains("\t2026-10-01 10:45"))
        #expect(!result.out.contains("Placed"))
    }

    @Test func addOutsideHoursSlides() {
        let result = CLIHarness().run("add", "T", "--at", "2026-10-03 23:30")
        #expect(result.out.contains("\t2026-10-05 09:30"))
        #expect(result.out.contains("Placed Mon 5 Oct 09:30 (asked Sat 3 Oct 23:30, outside working hours)"))
    }

    @Test func fixedKeepsWeekendTime() throws {
        let result = CLIHarness().run("add", "T", "--at", "2026-10-03 23:30", "--fixed", "--json")
        let object = try result.jsonObject()
        #expect(object["due"] as? String == "2026-10-03 23:30")
        #expect(object["fixed"] as? Bool == true)
        #expect(!result.out.contains("Placed") && !result.err.contains("Placed"))
    }

    @Test func fixedNeedsAt() {
        let result = CLIHarness().run("add", "T", "--fixed")
        #expect(result.code == 2)
        #expect(result.err.contains("--fixed needs --at"))
    }

    @Test func fixedRefusesDeadline() {
        #expect(CLIHarness().run("add", "T", "--at", "2026-10-02 10:00", "--fixed", "--deadline", "2026-10-05").code == 2)
    }

    @Test func durationLongerThanWorkingDayRefused() {
        let cli = CLIHarness()
        let result = cli.run("add", "T", "--duration", "12h")
        #expect(result.code == 2)
        #expect(result.err.contains("--duration is longer than the working day (10h)"))
        #expect(cli.run("add", "T", "--duration", "soon").code == 2)
    }

    @Test func aUsageErrorLeavesNoDatabase() {
        let cli = CLIHarness()
        #expect(cli.run("add", "T", "--duration", "12h").code == 2)
        #expect(!FileManager.default.fileExists(atPath: cli.database))
    }

    @Test func dateOnlyAtUsesWorkingStart() throws {
        let object = try CLIHarness().run("add", "T", "--at", "2026-10-05", "--json").jsonObject()
        #expect(object["due"] as? String == "2026-10-05 09:30")
        #expect(object["notBefore"] as? String == "2026-10-05 09:30")
    }

    @Test func dateOnlyInThePastIsRefused() {
        #expect(CLIHarness().run("add", "T", "--at", "2026-09-30").code == 2)
    }

    @Test func cannotUnfixAutoRunFromCLI() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run(
            "add", "T", "--at", "2026-10-02 10:00", "--prompt", "go", "--auto-run", "read", "--cwd", "/work/x", "--json"
        ).jsonObject()["id"] as? String)
        let result = cli.run("edit", id, "--no-fixed")
        #expect(result.code == 2)
        #expect(result.err.contains("fixed by auto-run"))
    }

    @Test func staleCopyWarnsOnStderr() throws {
        let cli = CLIHarness()
        try cli.store().replaceBusy([], at: CLIHarness.now.addingTimeInterval(-3 * 3600))
        let result = cli.run("add", "T")
        #expect(result.code == 0)
        #expect(result.err.contains("calendar copy is 3 h old"))
    }

    @Test func jsonCarriesScheduleFields() throws {
        let result = try freshHarness().run("add", "T", "--duration", "1h", "--deadline", "2026-10-02 12:00", "--json")
        let object = try result.jsonObject()
        #expect(object["durationMinutes"] as? Int == 60)
        #expect(object["fixed"] as? Bool == false)
        #expect(object["late"] as? Bool == false)
        #expect(object["deadline"] as? String == "2026-10-02 12:00")
        #expect(object["notBefore"] as? String == "2026-10-01 10:45")
    }

    @Test func defaultDurationIsFifteenMinutes() throws {
        let object = try CLIHarness().run("add", "T", "--json").jsonObject()
        #expect(object["durationMinutes"] as? Int == 15)
        #expect(object["deadline"] is NSNull)
    }

    @Test func addPrintsOtherMoves() throws {
        let cli = try freshHarness()
        // Occupies the first slot of the day; a later add with a tight deadline needs it.
        #expect(cli.run("add", "First", "--at", "2026-10-01 11:00", "--json").code == 0)
        let result = cli.run("add", "Urgent", "--at", "2026-10-01 11:00", "--duration", "30m", "--deadline", "2026-10-01 11:00")
        #expect(result.code == 0)
        #expect(result.out.contains("Moved: First to Thu 1 Oct "))
        #expect(result.out.contains("(reminder added)") || result.out.contains("(day full)") || result.out.contains("(meeting)"))
    }

    @Test func jsonKeepsStdoutPure() throws {
        let cli = try freshHarness()
        _ = cli.run("add", "First", "--at", "2026-10-01 11:00")
        let result = cli.run("add", "Urgent", "--at", "2026-10-01 11:00", "--duration", "30m", "--deadline", "2026-10-01 11:00", "--json")
        _ = try result.jsonObject()
        #expect(result.err.contains("Moved: First"))
    }

    @Test func editDurationFixedAndDeadline() throws {
        let cli = try freshHarness()
        let id = try #require(cli.run("add", "T", "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        let edited = try cli.run("edit", id, "--duration", "1h", "--fixed", "--json").jsonObject()
        #expect(edited["durationMinutes"] as? Int == 60)
        #expect(edited["fixed"] as? Bool == true)
        let unfixed = try cli.run("edit", id, "--no-fixed", "--deadline", "2026-10-05", "--json").jsonObject()
        #expect(unfixed["fixed"] as? Bool == false)
        #expect(unfixed["deadline"] as? String == "2026-10-05 19:30")
        let cleared = try cli.run("edit", id, "--deadline", "none", "--json").jsonObject()
        #expect(cleared["deadline"] is NSNull)
    }

    @Test func editAtOutsideHoursSlides() throws {
        let cli = try freshHarness()
        let id = try #require(cli.run("add", "T", "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        let result = cli.run("edit", id, "--at", "2026-10-04 12:00")
        #expect(result.out.contains("\t2026-10-05 09:30"))
        #expect(result.out.contains("Placed Mon 5 Oct 09:30 (asked Sun 4 Oct 12:00, outside working hours)"))
    }

    @Test func busyMeetingSlideHasNoOutsideHoursLine() throws {
        let meeting = try DateInterval(start: #require(StrictDate.parse("2026-10-01 11:00", calendar: CLIHarness.calendar)), duration: 3600)
        let cli = try freshHarness(busy: [meeting])
        let result = cli.run("add", "T", "--at", "2026-10-01 11:00")
        #expect(result.out.contains("\t2026-10-01 12:00"))
        #expect(!result.out.contains("Placed"))
    }

    @Test func doneReplansWithAFreshCopy() throws {
        let cli = try freshHarness()
        let id = try #require(cli.run("add", "T", "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        let result = cli.run("done", id)
        #expect(result.code == 0)
        #expect(result.out.hasPrefix(id))
    }
}
