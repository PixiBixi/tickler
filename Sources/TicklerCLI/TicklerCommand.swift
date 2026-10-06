import ArgumentParser
import Foundation
import TicklerCore

/// Hidden on every command: tests and experiments point the CLI at another database.
struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("db"), help: ArgumentHelp(visibility: .hidden))
    var db: String?
}

protocol TicklerSubcommand: ParsableCommand {
    func execute(_ context: CLIContext) throws
}

extension TicklerSubcommand {
    func run() throws {
        try execute(.live)
    }
}

public struct TicklerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tickler",
        abstract: "Reminders written by Claude Code, shown by Tickler.app.",
        version: Tickler.version,
        subcommands: [
            AddCommand.self, ListCommand.self, ShowCommand.self, DoneCommand.self, SnoozeCommand.self,
            EditCommand.self, RemoveCommand.self, ResumeCommand.self, StatusCommand.self, CompletionCommand.self,
            ImportAppleCommand.self, SkillCommand.self, HookCommand.self, VersionCommand.self,
        ]
    )

    public init() {}

    /// ArgumentParser exits 64 on bad usage and prints its own errors: this maps them to 0/1/2/3 and `error: <message>`.
    public static func main() {
        Foundation.exit(run(Array(CommandLine.arguments.dropFirst()), context: .live))
    }

    public static func run(_ arguments: [String], context: CLIContext) -> Int32 {
        do {
            var command = try parseAsRoot(arguments)
            if let subcommand = command as? TicklerSubcommand {
                try subcommand.execute(context)
                return 0
            }
            // `tickler help <cmd>` and the bare root: ArgumentParser's own commands print the right help.
            try command.run()
            return 0
        } catch let error as StoreError {
            context.stderr.line("error: \(error)")
            return 3
        } catch let error as CLIError {
            context.stderr.line("error: \(error)")
            if case .usage = error {
                return 2
            }
            return 1
        } catch {
            return report(error, context: context)
        }
    }

    private static func report(_ error: Error, context: CLIContext) -> Int32 {
        let code = exitCode(for: error)
        if code == .success {
            context.stdout.line(fullMessage(for: error))
            return 0
        }
        context.stderr.line("error: \(message(for: error))")
        return code == .validationFailure ? 2 : 1
    }
}
