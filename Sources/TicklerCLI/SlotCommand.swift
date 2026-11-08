import ArgumentParser
import Foundation
import TicklerCore

struct SlotCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "slot",
        abstract: "Show the first free slot without creating anything."
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: "How long it takes: 15m, 1h, 90m. Default: the default-duration setting.") var duration: String?
    @Option(help: "Look from the start of this day, YYYY-MM-DD. Default: now.") var day: String?
    @Flag(help: "Print JSON.") var json = false

    func execute(_ context: CLIContext) throws {
        let schedule = try context.scheduleForChecks(options)
        let minutes = try duration.map { try context.parseDurationMinutes($0, schedule: schedule) } ?? schedule.defaultDurationMinutes
        let from = try parseDay(context, schedule: schedule)
        let store = try context.openStore(options)
        guard let slot = try ScheduleRunner.slot(
            store: store, now: context.now(), calendar: context.calendar, minutes: minutes, notBefore: from
        ) else {
            throw CLIError.runtime("no free slot of \(minutes) min in the next 30 working days")
        }
        let end = slot.start.addingTimeInterval(TimeInterval(minutes * 60))
        let range = "\(context.scheduleStamp(slot.start))-\(context.clock(end))"
        if json {
            let object: [String: String] = [
                "start": StrictDate.format(slot.start, calendar: context.calendar),
                "end": StrictDate.format(end, calendar: context.calendar),
            ]
            try context.stdout.line(context.encodeJSON(object))
        } else {
            context.stdout.line(range)
        }
        if let warning = slot.warning {
            context.stderr.line("warning: \(warning)")
        }
    }

    private func parseDay(_ context: CLIContext, schedule: WorkSchedule) throws -> Date {
        guard let day else { return context.now() }
        guard day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else {
            throw CLIError.usage("--day expects YYYY-MM-DD, got \"\(day)\"")
        }
        return try context.parseScheduleDate(day, flag: "--day", dayTime: schedule.start).date
    }
}
