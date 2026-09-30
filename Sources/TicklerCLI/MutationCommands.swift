import ArgumentParser
import Foundation
import TicklerCore

struct DoneCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark a reminder as done.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.") var id: String
    @Flag(help: "Print the reminder as JSON.") var json = false

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let current = try context.loadReminder(id, from: store)
        // Already done: keep the original doneAt instead of restamping it.
        let reminder = current.status == .done ? current : try store.markDone(id)
        try context.printResult(reminder, store: store, json: json)
    }
}

struct SnoozeCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "snooze", abstract: "Push a reminder back.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.") var id: String
    @Option(name: .customLong("for"), help: "From now: 15m, 1h, 2d.") var duration: String?
    @Option(help: "New due date, \"YYYY-MM-DD HH:MM\" in local time.") var to: String?
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        guard (duration == nil) != (to == nil) else { throw ValidationError("pass exactly one of --for and --to") }
        if let duration, SnoozeDuration.parse(duration) == nil {
            throw ValidationError("--for expects a positive number and a unit m, h or d (15m, 1h, 2d), got \"\(duration)\"")
        }
    }

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        _ = try context.loadReminder(id, from: store)
        let due: Date
        if let duration, let interval = SnoozeDuration.parse(duration) {
            due = context.now().addingTimeInterval(interval)
        } else if let to {
            due = try context.parseFutureDate(to, flag: "--to")
        } else {
            throw CLIError.usage("pass exactly one of --for and --to")
        }
        try context.printResult(store.reschedule(id, to: due), store: store, json: json)
    }
}

struct EditCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change the title, date or notes.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.") var id: String
    @Option(help: "New title.") var title: String?
    @Option(help: "New due date, \"YYYY-MM-DD HH:MM\" in local time.") var at: String?
    @Option(help: "New notes, or - to read them from stdin.") var notes: String?
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        guard title != nil || at != nil || notes != nil else { throw ValidationError("nothing to change: pass --title, --at or --notes") }
        if let title, title.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("the title is empty")
        }
    }

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        _ = try context.loadReminder(id, from: store)
        let due = try at.map { try context.parseFutureDate($0, flag: "--at") }
        let updated = try store.update(id, title: title, notes: notes.map(context.readNotes), dueAt: due)
        try context.printResult(updated, store: store, json: json)
    }
}

struct RemoveCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a reminder.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.") var id: String

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        _ = try context.loadReminder(id, from: store)
        try store.delete(id)
    }
}
