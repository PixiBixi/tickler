import ArgumentParser
import TicklerCore

struct VersionCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print the Tickler version.")
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        context.stdout.line("tickler \(Tickler.version)")
    }
}
