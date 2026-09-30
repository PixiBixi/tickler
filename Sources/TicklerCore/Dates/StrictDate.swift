import Foundation

/// The only date format the CLI accepts and prints: `YYYY-MM-DD HH:MM`, local time.
public enum StrictDate {
    public static func parse(_ value: String, calendar: Calendar = .current) -> Date? {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/
        guard let match = value.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
        let components = DateComponents(
            year: Int(match.1), month: Int(match.2), day: Int(match.3), hour: Int(match.4), minute: Int(match.5)
        )
        guard let date = calendar.date(from: components) else { return nil }
        // Reject rollovers such as 2026-02-31 that Calendar silently normalizes.
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == components.year, back.month == components.month, back.day == components.day,
              back.hour == components.hour, back.minute == components.minute else { return nil }
        return date
    }

    public static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!)
    }
}
