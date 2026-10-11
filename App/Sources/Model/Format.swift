import Foundation
import TicklerCore

/// Dates as people read them, in the app's language.
enum Format {
    static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    /// "Today 11:00", "Tomorrow 09:30", "Mon 5 Oct 09:30".
    static func dueLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let clock = time(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Today \(clock)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow \(clock)")
        }
        let day = date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(locale))
        return "\(day) \(clock)"
    }

    /// "in 15 min", "1 hr ago".
    static func relative(_ date: Date, now: Date) -> String {
        if abs(date.timeIntervalSince(now)) < 60 {
            return String(localized: "now")
        }
        let formatter = cache.relative(locale: locale)
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// A date rendered with a fixed pattern in the app's language; the formatter is cached per pattern and locale.
    static func string(_ date: Date, pattern: String) -> String {
        cache.dateFormatter(pattern: pattern, locale: locale).string(from: date)
    }

    private static let cache = FormatterCache()

    static func weekdayShort(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(locale))
    }

    static func dayNumber(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().day().locale(locale))
    }

    static func title(for bucket: DueBucket?) -> String {
        switch bucket {
        case .overdue: String(localized: "Overdue")
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case .later: String(localized: "Later")
        case .waiting: String(localized: "Waiting")
        case nil: String(localized: "Done")
        }
    }

    /// The first lines of the notes, for rows and notifications.
    static func preview(_ notes: String, lines: Int = 2) -> String {
        notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .prefix(lines).joined(separator: " ")
    }
}

/// Formatters keyed on the locale identifier, so a language change builds fresh ones. Used from the main actor and tests.
private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [String: DateFormatter] = [:]
    private var relatives: [String: RelativeDateTimeFormatter] = [:]

    func dateFormatter(pattern: String, locale: Locale) -> DateFormatter {
        lock.withLock {
            let key = "\(locale.identifier)|\(pattern)"
            if let hit = dates[key] {
                return hit
            }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = pattern
            dates[key] = formatter
            return formatter
        }
    }

    func relative(locale: Locale) -> RelativeDateTimeFormatter {
        lock.withLock {
            if let hit = relatives[locale.identifier] {
                return hit
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .short
            relatives[locale.identifier] = formatter
            return formatter
        }
    }
}
