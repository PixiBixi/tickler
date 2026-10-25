import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct AutoRunCLITests {
    @Test func addAutoRunNeedsPrompt() {
        let result = CLIHarness().run("add", "check", "--at", "2026-10-02 10:00", "--session", "s1", "--auto-run", "read")
        #expect(result.code == 2)
        #expect(result.err.contains("--prompt"))
    }

    @Test func addAutoRunNeedsFolder() {
        let result = CLIHarness().run("add", "check", "--at", "2026-10-02 10:00", "--prompt", "rerun", "--auto-run", "read")
        #expect(result.code == 2)
        #expect(result.err.contains("--cwd"))
    }

    @Test func addAutoRunRejectsUnknownMode() {
        let cli = CLIHarness()
        #expect(cli.run("add", "check", "--at", "2026-10-02 10:00", "--prompt", "p", "--cwd", "/w", "--auto-run", "maybe").code == 2)
        #expect(cli.run("add", "check", "--at", "2026-10-02 10:00", "--prompt", "p", "--cwd", "/w", "--auto-run", "off").code == 2)
    }

    @Test func addAutoRunWrite() throws {
        let object = try CLIHarness().run(
            "add", "check", "--at", "2026-10-02 10:00", "--prompt", "rerun", "--cwd", "/w", "--auto-run", "write", "--json"
        ).jsonObject()
        #expect(object["autoRun"] as? String == "write")
    }

    @Test func addAutoRunTakesTheFolderFromTheSession() throws {
        let object = try CLIHarness().run(
            "add", "check", "--at", "2026-10-02 10:00", "--prompt", "rerun", "--session", "s1", "--auto-run", "read", "--json"
        ).jsonObject()
        #expect(object["autoRun"] as? String == "read")
    }

    @Test func editAutoRunOff() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run(
            "add", "check", "--at", "2026-10-02 10:00", "--prompt", "rerun", "--cwd", "/w", "--auto-run", "read", "--json"
        ).jsonObject()["id"] as? String)
        #expect(try cli.run("edit", id, "--auto-run", "write", "--json").jsonObject()["autoRun"] as? String == "write")
        #expect(try cli.run("edit", id, "--auto-run", "off", "--json").jsonObject()["autoRun"] is NSNull)
    }

    @Test func editAutoRunWithoutPromptIsRefused() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "check", "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        let result = cli.run("edit", id, "--auto-run", "read")
        #expect(result.code == 2)
        #expect(result.err.contains("resume prompt"))
    }

    @Test func jsonLastRunNullWithoutRuns() throws {
        let object = try CLIHarness().run("add", "plain", "--at", "2026-10-02 10:00", "--json").jsonObject()
        #expect(object["autoRun"] is NSNull)
        #expect(object["lastRun"] is NSNull)
    }

    private func seeded() throws -> (CLIHarness, String) {
        let cli = CLIHarness()
        let id = try #require(cli.run(
            "add", "check", "--at", "2026-10-02 10:00", "--prompt", "rerun", "--cwd", "/w", "--auto-run", "read", "--json"
        ).jsonObject()["id"] as? String)
        let store = try cli.store()
        let run = try #require(try store.startRun(id, at: CLIHarness.now))
        let result = RunResult(
            state: .succeeded, verdict: .watch, headline: "p99 up 8%", figures: ["p99 212ms", "p50 40ms"],
            nextStep: "Compare with the baseline\u{1B}[31m", denials: 1
        )
        try store.finishRun(run.id, result, at: CLIHarness.now.addingTimeInterval(120))
        return (cli, id)
    }

    @Test func jsonLastRunAfterFinish() throws {
        let (cli, id) = try seeded()
        let last = try #require(cli.run("show", id, "--json").jsonObject()["lastRun"] as? [String: Any])
        #expect(last["state"] as? String == "succeeded")
        #expect(last["verdict"] as? String == "watch")
        #expect(last["headline"] as? String == "p99 up 8%")
        #expect(last["figures"] as? [String] == ["p99 212ms", "p50 40ms"])
        #expect(last["denials"] as? Int == 1)
        #expect(last["startedAt"] as? String == "2026-10-01 10:45")
        #expect(last["endedAt"] as? String == "2026-10-01 10:47")
    }

    @Test func showPrintsLastRun() throws {
        let (cli, id) = try seeded()
        let out = cli.run("show", id).out
        #expect(out.contains("Last run: succeeded watch 2026-10-01 10:45"))
        #expect(out.contains("p99 up 8%"))
        #expect(out.contains("p99 212ms"))
        #expect(out.contains("Compare with the baseline\u{FFFD}[31m"))
        #expect(!out.contains("\u{1B}"))
    }

    @Test func showWithoutRunHasNoLastRunSection() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "plain", "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        #expect(!cli.run("show", id).out.contains("Last run"))
    }
}
