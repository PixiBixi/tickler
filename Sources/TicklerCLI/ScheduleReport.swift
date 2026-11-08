import Foundation
import TicklerCore

extension CLIContext {
    func runSchedule(_ store: ReminderStore, cause: ScheduleCause, touched: String?, isNew: Bool = false) throws -> ScheduleOutcome {
        try ScheduleRunner.run(store: store, now: now(), calendar: calendar, cause: cause, touched: touched, touchedIsNew: isNew)
    }

    /// "09:30" in the calendar's time zone.
    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "Mon 5 Oct 09:30": fixed English 24 h format in the calendar's time zone.
    func scheduleStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

/// Prints the reminder the command touched, where it landed, the other reminders the run moved and its warning.
/// `asked` is the time the user typed for a flexible reminder; with `--json` stdout stays pure JSON.
func printSchedule(
    _ outcome: ScheduleOutcome, placed: Reminder?, asked: Date?, context: CLIContext, store: ReminderStore, json: Bool = false
) throws {
    let notes = json ? context.stderr : context.stdout
    if let placed {
        try context.printResult(placed, store: store, json: json)
        if let asked, placed.dueAt != asked, try !isWorkingTime(asked, context: context, store: store) {
            let askedText = context.scheduleStamp(asked)
            notes.line("Placed \(context.scheduleStamp(placed.dueAt)) (asked \(askedText), outside working hours)")
        }
    }
    for move in outcome.moves {
        // Deleted after the commit: nothing left to report.
        guard let moved = try store.get(move.reminderId) else { continue }
        let title = moved.title.displaySafeLine
        notes.line("Moved: \(title) to \(context.scheduleStamp(move.to)) (\(move.reason.rawValue))")
    }
    if let warning = outcome.warning {
        context.stderr.line("warning: \(warning)")
    }
}

private func isWorkingTime(_ date: Date, context: CLIContext, store: ReminderStore) throws -> Bool {
    guard let window = try WorkingTime(schedule: store.schedule(), calendar: context.calendar).window(on: date) else { return false }
    return date >= window.start && date < window.end
}
