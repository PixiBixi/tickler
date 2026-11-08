import ArgumentParser
import Foundation
import TicklerCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change the work schedule the planner uses.",
        subcommands: [ConfigShowCommand.self, ConfigSetCommand.self],
        defaultSubcommand: ConfigShowCommand.self
    )
}

private func durationText(_ minutes: Int) -> String {
    minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
}

private func lunchText(_ lunch: Lunch?) -> String {
    lunch.map { "\(durationText($0.minutes))@\($0.from.text)-\($0.to.text)" } ?? "off"
}

struct ConfigShowCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the settings.")

    @OptionGroup var options: GlobalOptions
    @Flag(help: "Print JSON.") var json = false

    func execute(_ context: CLIContext) throws {
        let schedule = try context.openStore(options).schedule()
        // Calendar names are calendar text: only the count is shown.
        let count = schedule.busyCalendarIds.count
        if json {
            let object: [String: String] = [
                "scheduling": schedule.mode.rawValue,
                "working-days": schedule.daysText,
                "working-hours": schedule.hoursText,
                "default-duration": durationText(schedule.defaultDurationMinutes),
                "lunch": lunchText(schedule.lunch),
                "busy-calendars": "\(count)",
            ]
            try context.stdout.line(context.encodeJSON(object))
            return
        }
        context.stdout.line("scheduling \(schedule.mode.rawValue)")
        context.stdout.line("working-days \(schedule.daysText)")
        context.stdout.line("working-hours \(schedule.hoursText)")
        context.stdout.line("default-duration \(durationText(schedule.defaultDurationMinutes))")
        context.stdout.line("lunch \(lunchText(schedule.lunch))")
        context.stdout.line("busy-calendars \(count) chosen in Tickler.app")
    }
}

struct ConfigSetCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change a setting: scheduling, working-days, working-hours, default-duration or lunch.",
        discussion: """
        scheduling auto | place-only | off
        working-days mon-fri | mon,wed,fri    working-hours 09:30-19:30
        default-duration 15m | 1h             lunch off | 45m@12:00-14:00
        """
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "scheduling, working-days, working-hours, default-duration or lunch.") var key: String
    @Argument(help: "The new value.") var value: String

    func execute(_ context: CLIContext) throws {
        var schedule = try context.scheduleForChecks(options)
        try apply(to: &schedule)
        let store = try context.openStore(options)
        try store.setSchedule(schedule)
        context.notifyChange()
        let outcome = try context.runSchedule(store, cause: .settingsChanged, touched: nil)
        context.stdout.line("\(key) \(value)")
        try printSchedule(outcome, placed: nil, asked: nil, context: context, store: store)
    }

    private func apply(to schedule: inout WorkSchedule) throws {
        switch key {
        case "scheduling":
            guard let mode = SchedulingMode(rawValue: value) else {
                let choices = SchedulingMode.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.usage("scheduling expects one of \(choices), got \"\(value)\"")
            }
            schedule.mode = mode
        case "working-days":
            guard let days = WorkSchedule.parseDays(value) else {
                throw CLIError.usage("working-days expects days like mon-fri or mon,wed,fri, got \"\(value)\"")
            }
            schedule.workingDays = days
        case "working-hours":
            guard let (from, to) = WorkSchedule.parseHours(value) else {
                throw CLIError.usage("working-hours expects HH:MM-HH:MM with the start before the end, got \"\(value)\"")
            }
            schedule.start = from
            schedule.end = to
        case "default-duration":
            guard let minutes = WorkSchedule.parseDuration(value) else {
                throw CLIError.usage("default-duration expects a positive number and a unit m or h (15m, 1h), got \"\(value)\"")
            }
            schedule.defaultDurationMinutes = minutes
        case "lunch":
            guard let lunch = WorkSchedule.parseLunch(value) else {
                throw CLIError.usage("lunch expects off or <duration>@HH:MM-HH:MM (45m@12:00-14:00), got \"\(value)\"")
            }
            schedule.lunch = lunch
        case "busy-calendars":
            throw CLIError.usage("choose busy calendars in Tickler.app Settings")
        default:
            throw CLIError.usage("unknown setting \"\(key)\": use scheduling, working-days, working-hours, default-duration or lunch")
        }
    }
}
