import Foundation

/// Working days and hours as wall-clock windows; DST days keep their local hours.
public struct WorkingTime: Sendable {
    /// Calendar days looked at for one working-day step before giving up.
    static let maxGapDays = 14

    private let schedule: WorkSchedule
    private let calendar: Calendar

    public init(schedule: WorkSchedule, calendar: Calendar) {
        self.schedule = schedule
        self.calendar = calendar
    }

    /// False when the stored settings leave no window at all (no day, or hours that do not open).
    var isUsable: Bool {
        !schedule.workingDays.isDisjoint(with: 1 ... 7) && Self.clamped(schedule.start) < Self.clamped(schedule.end)
    }

    private static func clamped(_ time: TimeOfDay) -> Int {
        min(max(time.minutes, 0), 24 * 60 - 1)
    }

    func date(_ time: TimeOfDay, on day: Date) -> Date? {
        let minutes = Self.clamped(time)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    public func window(on day: Date) -> DateInterval? {
        guard isUsable, schedule.workingDays.contains(calendar.component(.weekday, from: day)),
              let from = date(schedule.start, on: day), let to = date(schedule.end, on: day), from < to else { return nil }
        return DateInterval(start: from, end: to)
    }

    /// The first window start that is not before `date`.
    public func nextWorkingStart(atOrAfter date: Date) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0 ..< Self.maxGapDays {
            if let window = window(on: day), window.start >= date {
                return window.start
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// The window start of the `n`th working day after `date`'s day.
    public func addingWorkingDays(_ n: Int, to date: Date) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0 ..< max(n, 0) {
            guard let next = nextWorkingDay(after: day) else { return nil }
            day = next
        }
        return n <= 0 ? nextWorkingStart(atOrAfter: day) : window(on: day)?.start
    }

    private func nextWorkingDay(after day: Date) -> Date? {
        var candidate = day
        for _ in 0 ..< Self.maxGapDays {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = next
            if window(on: candidate) != nil {
                return candidate
            }
        }
        return nil
    }
}
