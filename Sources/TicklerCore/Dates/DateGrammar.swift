import Foundation

/// Reads a free-text date in one language. Returns nil when the text is not fully understood.
public protocol DateGrammar: Sendable {
    var language: String { get }
    func parse(_ input: String, now: Date, calendar: Calendar) -> Date?
}

/// The words a language uses; `VocabularyGrammar` does the rest, identically for every language.
struct Vocabulary {
    var today: Set<String>
    var tomorrow: Set<String>
    var dayAfterTomorrow: Set<String>
    var next: Set<String>
    var filler: Set<String>
    var weekdays: [String: Int]
    var months: [String: Int]
    /// Phrases rewritten to a canonical `@H` hour token before tokenizing ("ce soir" gives "@18").
    var periods: [(String, Int)]
    var relativePrefix: String
    var hourUnits: Set<String>
    var minuteUnits: Set<String>
    var dayUnits: Set<String>
    var dayMonthOrder: Bool
    var usesMeridiem: Bool
}

struct VocabularyGrammar: DateGrammar {
    let language: String
    let words: Vocabulary

    /// Time used when only a day is given.
    static let defaultHour = 9

    /// What the tokens said, before turning it into a date.
    struct Parts {
        var dayOffset: Int?
        var weekday: Int?
        var monthDay: (month: Int, day: Int)?
        var time: (hour: Int, minute: Int)?

        var hasDay: Bool {
            dayOffset != nil || weekday != nil || monthDay != nil
        }
    }

    func parse(_ input: String, now: Date, calendar: Calendar) -> Date? {
        var text = Self.normalize(input)
        guard !text.isEmpty else { return nil }
        if let date = relative(text, now: now) {
            return date
        }
        for (phrase, hour) in words.periods {
            let pattern = "(?<=^| )\(NSRegularExpression.escapedPattern(for: phrase))(?=$| )"
            text = text.replacingOccurrences(of: pattern, with: "@\(hour)", options: .regularExpression)
        }
        if words.usesMeridiem {
            text = text.replacingOccurrences(of: #"(\d) (am|pm)\b"#, with: "$1$2", options: .regularExpression)
        }
        guard let parts = tokenize(text), parts.hasDay || parts.time != nil else { return nil }
        return resolve(parts, now: now, calendar: calendar)
    }

    private func tokenize(_ text: String) -> Parts? {
        var parts = Parts()
        var pendingNumber: Int?
        var pendingMonth: Int?
        for token in text.split(separator: " ").map(String.init) where !words.filler.contains(token) && !words.next.contains(token) {
            if words.today.contains(token) {
                parts.dayOffset = 0
            } else if words.tomorrow.contains(token) {
                parts.dayOffset = 1
            } else if words.dayAfterTomorrow.contains(token) {
                parts.dayOffset = 2
            } else if let value = words.weekdays[token] {
                parts.weekday = value
            } else if let month = words.months[token] {
                if words.dayMonthOrder, let day = pendingNumber {
                    parts.monthDay = (month, day)
                    pendingNumber = nil
                } else {
                    pendingMonth = month
                }
            } else if let parsed = parseTime(token) {
                guard parts.time == nil else { return nil }
                parts.time = parsed
            } else if let number = Int(token), (1 ... 31).contains(number) {
                if !words.dayMonthOrder, let month = pendingMonth {
                    parts.monthDay = (month, number)
                    pendingMonth = nil
                } else {
                    pendingNumber = number
                }
            } else if let numeric = Self.numericDate(token, dayFirst: words.dayMonthOrder) {
                parts.monthDay = numeric
            } else {
                return nil
            }
        }
        return pendingNumber == nil && pendingMonth == nil ? parts : nil
    }

    private func resolve(_ parts: Parts, now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        var day: Date
        if let monthDay = parts.monthDay {
            var components = calendar.dateComponents([.year], from: now)
            components.month = monthDay.month
            components.day = monthDay.day
            guard let candidate = calendar.date(from: components),
                  calendar.component(.day, from: candidate) == monthDay.day else { return nil }
            day = candidate < startOfToday ? calendar.date(byAdding: .year, value: 1, to: candidate)! : candidate
        } else if let weekday = parts.weekday {
            let ahead = (weekday - calendar.component(.weekday, from: now) + 7) % 7
            day = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: startOfToday)!
        } else {
            day = calendar.date(byAdding: .day, value: parts.dayOffset ?? 0, to: startOfToday)!
        }
        let clock = parts.time ?? (Self.defaultHour, 0)
        guard var result = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day) else { return nil }
        // A bare time already past today means tomorrow; an explicit day stays as asked.
        if !parts.hasDay, result <= now {
            result = calendar.date(byAdding: .day, value: 1, to: result)!
        }
        return result
    }

    private func relative(_ text: String, now: Date) -> Date? {
        let prefix = NSRegularExpression.escapedPattern(for: words.relativePrefix)
        let pattern = "^\(prefix) (\\d+) ?([a-z]+)(?: (\\d+) ?([a-z]*))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let amount = group(1).flatMap(Int.init), let unit = group(2) else { return nil }
        var seconds: Double
        if words.hourUnits.contains(unit) {
            seconds = Double(amount) * 3600
            if let extra = group(3).flatMap(Int.init) {
                let extraUnit = group(4) ?? ""
                guard extraUnit.isEmpty || words.minuteUnits.contains(extraUnit), extra < 60 else { return nil }
                seconds += Double(extra) * 60
            }
        } else if words.minuteUnits.contains(unit), group(3) == nil {
            seconds = Double(amount) * 60
        } else if words.dayUnits.contains(unit), group(3) == nil {
            seconds = Double(amount) * 86400
        } else {
            return nil
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    private func parseTime(_ token: String) -> (hour: Int, minute: Int)? {
        if token.hasPrefix("@"), let hour = Int(token.dropFirst()) {
            return (hour, 0)
        }
        var hour: Int?
        var minute = 0
        if let match = token.wholeMatch(of: /(\d{1,2}):(\d{2})/) {
            hour = Int(match.1)
            minute = Int(match.2) ?? 0
        } else if !words.usesMeridiem, let match = token.wholeMatch(of: /(\d{1,2})h(\d{2})?/) {
            hour = Int(match.1)
            minute = match.2.flatMap { Int($0) } ?? 0
        } else if words.usesMeridiem, let match = token.wholeMatch(of: /(\d{1,2})(?::(\d{2}))?(am|pm)/) {
            guard let value = Int(match.1), (1 ... 12).contains(value) else { return nil }
            hour = value % 12 + (match.3 == "pm" ? 12 : 0)
            minute = match.2.flatMap { Int($0) } ?? 0
        }
        guard let hour, (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func numericDate(_ token: String, dayFirst: Bool) -> (month: Int, day: Int)? {
        guard let match = token.wholeMatch(of: /(\d{1,2})\/(\d{1,2})/),
              let first = Int(match.1), let second = Int(match.2) else { return nil }
        let (day, month) = dayFirst ? (first, second) : (second, first)
        guard (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        return (month, day)
    }

    static func normalize(_ input: String) -> String {
        input
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "aujourd'hui", with: "aujourdhui")
            .replacingOccurrences(of: "apres demain", with: "apres-demain")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
