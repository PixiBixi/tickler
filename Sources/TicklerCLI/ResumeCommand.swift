import ArgumentParser
import Foundation
import TicklerCore

struct ResumeCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Bring a reminder's Claude session back in WezTerm.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.") var id: String

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let reminder = try context.loadReminder(id, from: store)
        guard let sessionId = reminder.sessionId else { throw CLIError.runtime("reminder \(id) has no Claude session") }
        guard let driver = context.makeDriver() else { throw CLIError.runtime("WezTerm not found") }
        let outcome = try SessionResumer(driver: driver).resume(sessionId: sessionId, fallbackCwd: reminder.cwd)
        context.stdout.line(Self.describe(outcome))
        if let pane = Self.callingPaneToClose(after: outcome, environment: context.environment) {
            // The pane the user typed in is now redundant; failing to close it must not fail the resume.
            try? driver.killPane(pane)
        }
    }

    static func describe(_ outcome: ResumeOutcome) -> String {
        switch outcome {
        case let .focused(pane): "focused the running session in pane \(pane)"
        case let .spawned(pane): "resumed the session in a new tab, pane \(pane)"
        case .startedWindow: "started WezTerm with the resumed session"
        }
    }

    /// The caller's pane, when it is a human's shell in another pane: never the pane of a running Claude session.
    static func callingPaneToClose(after outcome: ResumeOutcome, environment: [String: String]) -> String? {
        guard let calling = environment["WEZTERM_PANE"], !calling.isEmpty, environment["CLAUDECODE"] == nil else { return nil }
        switch outcome {
        case let .focused(pane), let .spawned(pane): return pane == calling ? nil : calling
        case .startedWindow: return nil
        }
    }
}
