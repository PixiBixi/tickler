import ArgumentParser
import Foundation
import TicklerCore

enum DueOption: String, ExpressibleByArgument, CaseIterable {
    case today, week, overdue, all

    var filter: ReminderFilter.Due {
        switch self {
        case .today: .today
        case .week: .week
        case .overdue: .overdue
        case .all: .all
        }
    }
}

enum StatusOption: String, ExpressibleByArgument, CaseIterable {
    case open, done

    var status: Reminder.Status {
        self == .open ? .open : .done
    }
}

struct ListCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List reminders; today includes overdue.")

    @OptionGroup var options: GlobalOptions
    @Option(help: "today (default, overdue included), week, overdue or all.") var due: DueOption = .today
    @Option(help: "Only this project (last folder name of the session).") var project: String?
    @Option(help: "open (default) or done.") var status: StatusOption = .open
    @Flag(help: "Print a JSON array.") var json = false

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let reminders = try store.list(ReminderFilter(due: due.filter, status: status.status, project: project))
        if json {
            try context.stdout.line(context.encodeJSON(reminders.map { try context.json($0, store: store) }))
        } else {
            for reminder in reminders {
                context.stdout.line(context.listLine(reminder))
            }
        }
    }
}

struct ShowCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one reminder.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.", completion: .custom(IDCompletion.complete)) var id: String
    @Flag(help: "Print the reminder as JSON.") var json = false

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let reminder = try context.loadReminder(id, from: store)
        if json {
            try context.stdout.line(context.encodeJSON(context.json(reminder, store: store)))
        } else {
            try context.stdout.line(context.detail(reminder, links: store.links(for: id)))
        }
    }
}
