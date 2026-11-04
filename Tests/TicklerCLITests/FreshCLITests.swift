import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct FreshCLITests {
    @Test func addFreshRoundTrip() throws {
        let cli = CLIHarness()
        let object = try cli.run(
            "add", "handoff", "--at", "2026-10-02 10:00", "--prompt", "Read HANDOFF.md", "--cwd", "/w", "--fresh", "--json"
        ).jsonObject()
        #expect(object["fresh"] as? Bool == true)
        let id = try #require(object["id"] as? String)
        #expect(try cli.run("show", id, "--json").jsonObject()["fresh"] as? Bool == true)
        #expect(try cli.run("add", "plain", "--at", "2026-10-02 10:00", "--json").jsonObject()["fresh"] as? Bool == false)
    }

    @Test func addFreshNeedsPrompt() {
        let result = CLIHarness().run("add", "handoff", "--at", "2026-10-02 10:00", "--cwd", "/w", "--fresh")
        #expect(result.code == 2)
        #expect(result.err.contains("--fresh needs --prompt"))
    }

    @Test func addFreshWithoutSessionKeepsTheCurrentFolder() throws {
        let cli = CLIHarness()
        let object = try cli.run("add", "handoff", "--at", "2026-10-02 10:00", "--prompt", "go", "--fresh", "--json").jsonObject()
        #expect(object["sessionId"] is NSNull)
        #expect(object["cwd"] as? String == "/work/current")
    }

    @Test func editTogglesFresh() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "check", "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        #expect(try cli.run("edit", id, "--fresh", "--json").jsonObject()["fresh"] as? Bool == true)
        #expect(try cli.run("edit", id, "--no-fresh", "--json").jsonObject()["fresh"] as? Bool == false)
    }

    @Test func editWithNothingToChangeNamesFresh() {
        let result = CLIHarness().run("edit", "abcdef")
        #expect(result.code == 2)
        #expect(result.err.contains("--fresh"))
    }

    @Test func freshResumeWithoutSessionGetsPastTheSessionCheck() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run(
            "add", "handoff", "--at", "2026-10-02 10:00", "--prompt", "go", "--cwd", "/w", "--fresh", "--json"
        ).jsonObject()["id"] as? String)
        let result = cli.run("resume", id)
        #expect(result.code == 1)
        #expect(result.err.contains("no supported terminal found"))
    }
}
