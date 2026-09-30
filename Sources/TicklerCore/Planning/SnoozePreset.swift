import Foundation

/// The quick "later" choices shown in the app and in notifications.
public enum SnoozePreset: String, CaseIterable, Sendable {
    case fifteenMinutes
    case oneHour
    case thisAfternoon
    case tomorrowMorning
    case nextMonday

    /// The presets that make sense now: "this afternoon" disappears once 14:00 is near.
    public static func available(now: Date, calendar: Calendar = .current) -> [SnoozePreset] {
        allCases.filter { $0.date(from: now, calendar: calendar) != nil }
    }

    public func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .fifteenMinutes:
            return now.addingTimeInterval(15 * 60)
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .thisAfternoon:
            let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now)!
            return afternoon.timeIntervalSince(now) >= 30 * 60 ? afternoon : nil
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: 9, minute: 30, second: 0, of: tomorrow)
        case .nextMonday:
            let monday = 2
            let ahead = (monday - calendar.component(.weekday, from: now) + 7) % 7
            let day = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: 9, minute: 30, second: 0, of: day)
        }
    }
}

public extension SessionResumer {
    /// Whether the session still runs somewhere, to show "running" or "ended" next to Resume.
    func isRunning(sessionId: String) -> Bool {
        livePid(of: sessionId) != nil
    }
}
