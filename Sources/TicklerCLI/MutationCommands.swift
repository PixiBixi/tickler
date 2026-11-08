import ArgumentParser
import Foundation
import TicklerCore

struct DoneCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark a reminder as done.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.", completion: .custom(IDCompletion.complete)) var id: String
    @Flag(help: "Print the reminder as JSON.") var json = false

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let current = try context.loadReminder(id, from: store)
        // Already done: keep the original doneAt instead of restamping it.
        guard current.status != .done else { return try context.printResult(current, store: store, json: json) }
        let reminder = try store.markDone(id)
        // Nothing touched: a fresh copy replans the day, a stale one writes nothing.
        let outcome = try context.runSchedule(store, cause: .routine, touched: nil)
        try printSchedule(outcome, placed: reminder, asked: nil, context: context, store: store, json: json)
    }
}

struct SnoozeCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "snooze", abstract: "Push a reminder back.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.", completion: .custom(IDCompletion.complete)) var id: String
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
        var asked: Date?
        if let duration, let interval = SnoozeDuration.parse(duration) {
            due = context.now().addingTimeInterval(interval)
        } else if let to {
            due = try context.parseFutureDate(to, flag: "--to")
            asked = due
        } else {
            throw CLIError.usage("pass exactly one of --for and --to")
        }
        let moved = try store.reschedule(id, to: due)
        let outcome = try context.runSchedule(store, cause: .routine, touched: id)
        let shown = try store.require(id)
        try printSchedule(outcome, placed: shown, asked: moved.holdsItsTime ? nil : asked, context: context, store: store, json: json)
    }
}

struct EditCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change the title, date or notes.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.", completion: .custom(IDCompletion.complete)) var id: String
    @Option(help: "New title.") var title: String?
    @Option(help: "New earliest time (due date for a fixed reminder), \"YYYY-MM-DD HH:MM\" or \"YYYY-MM-DD\", local.") var at: String?
    @Option(help: "New duration: 15m, 1h, 90m.") var duration: String?
    @Flag(inversion: .prefixedNo, help: "Pin the reminder to its time, or let the planner move it again.") var fixed: Bool?
    @Option(help: "Latest acceptable start, \"YYYY-MM-DD[ HH:MM]\", or none to remove it.") var deadline: String?
    @Option(help: "New notes, or - to read them from stdin.") var notes: String?
    @Option(help: "First message sent to Claude on resume; an empty string removes it.") var prompt: String?
    @Option(help: "Event that makes it due now: \(Trigger.usage); an empty string removes it.") var when: String?
    @Option(help: "Run the resume prompt in the background when due, in Tickler.app: \(AutoRunOption.editUsage).")
    var autoRun: AutoRunOption?
    @Flag(inversion: .prefixedNo, help: "Resume starts a new session in the folder with the prompt; use it with a handoff file.")
    var fresh: Bool?
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        let changes: [Any?] = [title, at, duration, fixed, deadline, notes, prompt, when, autoRun, fresh]
        guard changes.contains(where: { $0 != nil }) else {
            throw ValidationError(
                "nothing to change: pass --title, --at, --duration, --fixed, --deadline, --notes, --prompt, --when, --auto-run or --fresh"
            )
        }
        if let when, !when.isEmpty, Trigger(when) == nil {
            throw ValidationError("--when expects \(Trigger.usage), got \"\(when)\"")
        }
        if let title, title.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("the title is empty")
        }
    }

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let existing = try context.loadReminder(id, from: store)
        let schedule = try store.schedule()
        let asked = try at.map { try context.parseScheduleDate($0, flag: "--at", dayTime: schedule.start) }
        let minutes = try duration.map { try context.parseDurationMinutes($0, schedule: schedule) }
        let latest = try parseDeadline(context, schedule: schedule)
        let newNotes = notes.map(context.readNotes)
        let trigger = when.flatMap(Trigger.init)
        // Checked before any write, against the links the edit leaves.
        if let trigger {
            let current = try store.links(for: id)
            let links = newNotes.map {
                LinkExtractor.linksAfterNotesChange(reminderId: id, oldNotes: existing.notes, newNotes: $0, current: current)
            } ?? current
            try requireSupportedLink(trigger, links, gitlabHosts: GitLabHosts.current(environment: context.environment))
        }
        // Pinning first, so that --at below moves the right field; a refusal leaves everything untouched.
        if let fixed {
            do {
                _ = try store.setFixed(id, fixed)
            } catch let error as StoreError {
                guard case .invalid = error else { throw error }
                throw CLIError.usage("\(error)")
            }
        }
        do {
            _ = try store.update(id, title: title, notes: newNotes, dueAt: asked?.date, resumePrompt: prompt)
        } catch let error as StoreError where error == .autoRunNeedsPrompt || error == .autoRunNeedsFolder {
            throw CLIError.usage("--auto-run: \(error)")
        }
        if when != nil {
            _ = try store.setTrigger(id, trigger)
        }
        if let fresh {
            _ = try store.setFresh(id, fresh)
        }
        if let autoRun {
            do {
                _ = try store.setAutoRun(id, autoRun.mode)
            } catch let error as StoreError where error != .notFound(id) {
                throw CLIError.usage("--auto-run: \(error)")
            }
        }
        if let minutes {
            _ = try store.setDuration(id, minutes: minutes)
        }
        if deadline != nil {
            _ = try store.setDeadline(id, latest)
        }
        let outcome = try context.runSchedule(store, cause: .routine, touched: id)
        let shown = try store.require(id)
        let typed = asked.flatMap { $0.hasTime && !shown.holdsItsTime ? $0.date : nil }
        try printSchedule(outcome, placed: shown, asked: typed, context: context, store: store, json: json)
    }

    /// `none` removes the deadline; nil when the flag is absent or `none`.
    private func parseDeadline(_ context: CLIContext, schedule: WorkSchedule) throws -> Date? {
        guard let deadline, deadline != "none" else { return nil }
        return try context.parseScheduleDate(deadline, flag: "--deadline", dayTime: schedule.end).date
    }
}

struct RemoveCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a reminder.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.", completion: .custom(IDCompletion.complete)) var id: String

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        let reminder = try context.loadReminder(id, from: store)
        try store.delete(id)
        context.stdout.line("deleted\t" + context.summaryLine(reminder))
    }
}
