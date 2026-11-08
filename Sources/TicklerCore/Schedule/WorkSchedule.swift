import Foundation

/// Minutes since midnight, written `HH:mm`.
public struct TimeOfDay: Codable, Hashable, Sendable, Comparable {
    public var minutes: Int

    public init(minutes: Int) {
        self.minutes = minutes
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        minutes = hour * 60 + minute
    }

    public var text: String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutes < rhs.minutes
    }
}

public struct Lunch: Codable, Hashable, Sendable {
    public var minutes: Int
    public var from: TimeOfDay
    public var to: TimeOfDay

    public init(minutes: Int, from: TimeOfDay, to: TimeOfDay) {
        self.minutes = minutes
        self.from = from
        self.to = to
    }
}

/// How far the planner goes: `auto` places and moves, `placeOnly` only places a new reminder, `off` never avoids anything.
public enum SchedulingMode: String, Codable, CaseIterable, Sendable {
    case auto
    case placeOnly = "place-only"
    case off
}

public struct WorkSchedule: Codable, Hashable, Sendable {
    /// Foundation weekdays: 1 = Sunday ... 7 = Saturday.
    public var workingDays: Set<Int>
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var defaultDurationMinutes: Int
    public var lunch: Lunch?
    public var busyCalendarIds: [String]
    public var mode: SchedulingMode

    public init(
        workingDays: Set<Int>,
        start: TimeOfDay,
        end: TimeOfDay,
        defaultDurationMinutes: Int,
        lunch: Lunch? = nil,
        busyCalendarIds: [String] = [],
        mode: SchedulingMode = .auto
    ) {
        self.workingDays = workingDays
        self.start = start
        self.end = end
        self.defaultDurationMinutes = defaultDurationMinutes
        self.lunch = lunch
        self.busyCalendarIds = busyCalendarIds
        self.mode = mode
    }

    /// A schedule stored before `mode` existed reads as automatic.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workingDays = try values.decode(Set<Int>.self, forKey: .workingDays)
        start = try values.decode(TimeOfDay.self, forKey: .start)
        end = try values.decode(TimeOfDay.self, forKey: .end)
        defaultDurationMinutes = try values.decode(Int.self, forKey: .defaultDurationMinutes)
        lunch = try values.decodeIfPresent(Lunch.self, forKey: .lunch)
        busyCalendarIds = try values.decode([String].self, forKey: .busyCalendarIds)
        mode = try values.decodeIfPresent(SchedulingMode.self, forKey: .mode) ?? .auto
    }

    public static let standard = WorkSchedule(
        workingDays: [2, 3, 4, 5, 6],
        start: TimeOfDay(minutes: 9 * 60 + 30),
        end: TimeOfDay(minutes: 19 * 60 + 30),
        defaultDurationMinutes: 15
    )
}

public extension WorkSchedule {
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    /// Display order of a week, Monday first.
    private static let weekOrder = [2, 3, 4, 5, 6, 7, 1]

    static func parseDays(_ text: String) -> Set<Int>? {
        var days = Set<Int>()
        for item in text.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            let ends = item.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard ends.count <= 2, let first = dayNames.firstIndex(of: ends[0]) else { return nil }
            if ends.count == 1 {
                days.insert(first + 1)
                continue
            }
            guard let last = dayNames.firstIndex(of: ends[1]) else { return nil }
            var day = first
            while true {
                days.insert(day + 1)
                if day == last {
                    break
                }
                day = (day + 1) % 7
            }
        }
        return days.isEmpty ? nil : days
    }

    static func parseHours(_ text: String) -> (TimeOfDay, TimeOfDay)? {
        let ends = text.split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2, let from = TimeOfDay(String(ends[0])), let to = TimeOfDay(String(ends[1])),
              from < to else { return nil }
        return (from, to)
    }

    /// Minutes from `15m`, `1h` or `90m`; zero or negative is rejected.
    static func parseDuration(_ text: String) -> Int? {
        guard let unit = text.last, let value = Int(text.dropLast()), value > 0 else { return nil }
        switch unit {
        case "m": return value
        case "h":
            let (minutes, overflow) = value.multipliedReportingOverflow(by: 60)
            return overflow ? nil : minutes
        default: return nil
        }
    }

    /// `off` gives `.some(nil)`; `45m@12:00-14:00` a lunch that fits its window; anything else `nil`.
    static func parseLunch(_ text: String) -> Lunch?? {
        if text == "off" {
            return .some(nil)
        }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = parseDuration(String(parts[0])),
              let (from, to) = parseHours(String(parts[1])), minutes <= to.minutes - from.minutes else { return nil }
        return .some(Lunch(minutes: minutes, from: from, to: to))
    }

    var daysText: String {
        let flags = Self.weekOrder.map { workingDays.contains($0) }
        var parts: [String] = []
        var index = 0
        while index < flags.count {
            guard flags[index] else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < flags.count, flags[last + 1] {
                last += 1
            }
            let name = { (position: Int) in Self.dayNames[Self.weekOrder[position] - 1] }
            if last - index >= 2 {
                parts.append("\(name(index))-\(name(last))")
            } else {
                parts.append(contentsOf: (index ... last).map(name))
            }
            index = last + 1
        }
        return parts.joined(separator: ",")
    }

    var hoursText: String {
        "\(start.text)-\(end.text)"
    }

    var workingMinutes: Int {
        max(0, end.minutes - start.minutes - (lunch?.minutes ?? 0))
    }
}
