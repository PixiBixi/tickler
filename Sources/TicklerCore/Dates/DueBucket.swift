import Foundation

/// The groups reminders are shown in, from most to least pressing.
public enum DueBucket: String, CaseIterable, Sendable {
    case overdue
    case today
    case tomorrow
    case later
    case waiting

    public static func of(_ due: Date, now: Date, calendar: Calendar = .current) -> DueBucket {
        if due < now {
            return .overdue
        }
        if calendar.isDate(due, inSameDayAs: now) {
            return .today
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        if calendar.isDate(due, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .later
    }

    /// A reminder waiting for an event and not due before tomorrow is shown apart: its date is only the fallback.
    public static func of(_ reminder: Reminder, now: Date, calendar: Calendar = .current) -> DueBucket {
        let bucket = of(reminder.dueAt, now: now, calendar: calendar)
        guard reminder.isWaiting, bucket == .tomorrow || bucket == .later else { return bucket }
        return .waiting
    }
}
