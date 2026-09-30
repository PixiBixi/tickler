import ArgumentParser
import Foundation
import TicklerCore

struct ImportAppleCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "import-apple",
        abstract: "One-shot import of the open reminders of an Apple Reminders list. The list is left untouched."
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: "The Apple Reminders list to import.") var list = "Claude"

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let rows = try AppleImport.decode(context.fetchAppleReminders(list))
        let summary = try AppleImport.importRows(rows, into: store)
        for title in summary.withoutDate {
            context.stdout.line("no date, skipped: \(title)")
        }
        context.stdout.line(
            "imported \(summary.imported), skipped \(summary.alreadyImported) (already imported), \(summary.withoutDate.count) without date"
        )
    }
}
