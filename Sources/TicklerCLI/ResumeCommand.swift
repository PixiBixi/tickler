import ArgumentParser
import Foundation
import TicklerCore

struct ResumeCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Bring a reminder's Claude session back in WezTerm, Ghostty or iTerm2."
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.", completion: .custom(IDCompletion.complete)) var id: String

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let reminder = try context.loadReminder(id, from: store)
        guard let sessionId = reminder.sessionId else { throw CLIError.runtime("reminder \(id) has no Claude session") }
        guard let driver = context.makeDriver() else { throw CLIError.runtime("no supported terminal found (WezTerm, Ghostty or iTerm2)") }
        let outcome = try SessionResumer(driver: driver)
            .resume(sessionId: sessionId, fallbackCwd: reminder.cwd, prompt: reminder.resumePrompt)
        context.stdout.line(Self.describe(outcome))
        if let pane = Self.callingPaneToClose(after: outcome, environment: context.environment) {
            // The pane the user typed in is now redundant; failing to close it must not fail the resume.
            try? driver.killPane(pane)
        }
    }

    static func describe(_ outcome: ResumeOutcome) -> String {
        switch outcome {
        case let .focused(pane, typed):
            "focused the running session in pane \(pane)" + (typed ? ", prompt typed, press Return to send" : "")
        case let .spawned(pane): "resumed the session in a new tab, pane \(pane)"
        case .startedWindow: "started the terminal with the resumed session"
        }
    }

    /// The caller's pane, when it is a human's shell in another pane: never the pane of a running Claude session.
    static func callingPaneToClose(after outcome: ResumeOutcome, environment: [String: String]) -> String? {
        guard let wezterm = environment["WEZTERM_PANE"], !wezterm.isEmpty, environment["CLAUDECODE"] == nil else { return nil }
        let calling = "wezterm:\(wezterm)"
        switch outcome {
        case let .focused(pane, _), let .spawned(pane): return pane == calling ? nil : calling
        case .startedWindow: return nil
        }
    }
}
