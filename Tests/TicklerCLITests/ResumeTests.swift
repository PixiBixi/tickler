import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct ResumeTests {
    @Test func reminderWithoutSessionIsRuntimeError() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "No session", "--at", "2026-10-02 09:00", "--json").jsonObject()["id"] as? String)
        let result = cli.run("resume", id)
        #expect(result.code == 1)
        #expect(result.err == "error: reminder \(id) has no Claude session\n")
    }

    @Test func missingTerminalIsRuntimeError() throws {
        let cli = CLIHarness()
        let id = try #require(
            cli.run(
                "add", "Has session", "--at", "2026-10-02 09:00", "--session", "6e077b7d-ca93-41cd-9fe9-c2af0815fc60", "--json"
            ).jsonObject()["id"] as? String
        )
        let result = cli.run("resume", id)
        #expect(result.code == 1)
        #expect(result.err.contains("no supported terminal found"))
    }

    @Test func unknownIdExitsWithThree() {
        #expect(CLIHarness().run("resume", "zzzzzz").code == 3)
    }

    struct PaneCase: Sendable {
        let outcome: ResumeOutcome
        let environment: [String: String]
        let expected: String?
    }

    @Test(arguments: [
        PaneCase(outcome: .focused(paneId: "wezterm:5"), environment: ["WEZTERM_PANE": "9"], expected: "wezterm:9"),
        PaneCase(outcome: .spawned(paneId: "iterm:ABC"), environment: ["WEZTERM_PANE": "9"], expected: "wezterm:9"),
        PaneCase(outcome: .focused(paneId: "wezterm:9"), environment: ["WEZTERM_PANE": "9"], expected: nil),
        PaneCase(outcome: .focused(paneId: "wezterm:5"), environment: ["WEZTERM_PANE": "9", "CLAUDECODE": "1"], expected: nil),
        PaneCase(outcome: .focused(paneId: "wezterm:5"), environment: [:], expected: nil),
        PaneCase(outcome: .startedWindow, environment: ["WEZTERM_PANE": "9"], expected: nil),
    ])
    func closesOnlyAHumanShellInAnotherPane(_ row: PaneCase) {
        #expect(ResumeCommand.callingPaneToClose(after: row.outcome, environment: row.environment) == row.expected)
    }
}
