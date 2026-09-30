import Foundation

public enum Grammars {
    public static let french: DateGrammar = VocabularyGrammar(language: "fr", words: Vocabulary(
        today: ["aujourdhui"],
        tomorrow: ["demain"],
        dayAfterTomorrow: ["apres-demain"],
        next: ["prochain", "prochaine"],
        filler: ["a", "le", "la", "vers", "pour"],
        weekdays: [
            "dimanche": 1, "dim": 1, "lundi": 2, "lun": 2, "mardi": 3, "mar": 3, "mercredi": 4, "mer": 4,
            "jeudi": 5, "jeu": 5, "vendredi": 6, "ven": 6, "samedi": 7, "sam": 7,
        ],
        months: [
            "janvier": 1, "janv": 1, "fevrier": 2, "fevr": 2, "fev": 2, "mars": 3, "avril": 4, "avr": 4, "mai": 5,
            "juin": 6, "juillet": 7, "juil": 7, "aout": 8, "septembre": 9, "sept": 9, "octobre": 10, "oct": 10,
            "novembre": 11, "nov": 11, "decembre": 12, "dec": 12,
        ],
        periods: [
            ("cet apres-midi", 14), ("ce matin", 9), ("ce soir", 18),
            ("apres-midi", 14), ("matin", 9), ("soir", 18), ("midi", 12),
        ],
        relativePrefix: "dans",
        hourUnits: ["h", "heure", "heures"],
        minuteUnits: ["min", "mn", "minute", "minutes"],
        dayUnits: ["j", "jour", "jours"],
        dayMonthOrder: true,
        usesMeridiem: false
    ))

    public static let english: DateGrammar = VocabularyGrammar(language: "en", words: Vocabulary(
        today: ["today"],
        tomorrow: ["tomorrow", "tmrw"],
        dayAfterTomorrow: [],
        next: ["next", "this"],
        filler: ["at", "on", "the", "by"],
        weekdays: [
            "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4, "wed": 4,
            "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
        ],
        months: [
            "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
            "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
            "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
        ],
        periods: [
            ("this morning", 9), ("this afternoon", 14), ("this evening", 18), ("tonight", 18),
            ("morning", 9), ("afternoon", 14), ("evening", 18), ("noon", 12),
        ],
        relativePrefix: "in",
        hourUnits: ["h", "hr", "hrs", "hour", "hours"],
        minuteUnits: ["m", "min", "mins", "minute", "minutes"],
        dayUnits: ["d", "day", "days"],
        dayMonthOrder: false,
        usesMeridiem: true
    ))

    public static let all: [DateGrammar] = [french, english]
}

/// Free-text dates for people: ISO first, then the preferred language, then the others. Never returns a past date.
public struct DateParser: Sendable {
    public let grammars: [DateGrammar]

    public init(preferred: String, grammars: [DateGrammar] = Grammars.all) {
        let language = String(preferred.prefix(2)).lowercased()
        self.grammars = grammars.filter { $0.language == language } + grammars.filter { $0.language != language }
    }

    public func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let candidate = StrictDate.parse(input, calendar: calendar)
            ?? grammars.lazy.compactMap { $0.parse(input, now: now, calendar: calendar) }.first
        guard let candidate, candidate > now else { return nil }
        return candidate
    }
}
