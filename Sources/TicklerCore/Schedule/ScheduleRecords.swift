import Foundation
import GRDB

/// Why the planner moved a reminder; the raw values are shown to the user as is.
public enum MoveReason: String, Codable, Sendable {
    case meeting
    case slotFreed = "slot freed"
    case dayFull = "day full"
    case reminderAdded = "reminder added"
    case settingsChanged = "settings changed"
    case migration
    /// An earlier slot opened or a day filled without a calendar change: a done, an edit or a snooze.
    case replanned
}

public struct ScheduleMove: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scheduleMove"

    public var id: Int64?
    public var reminderId: String
    public var from: Date
    public var to: Date
    public var reason: MoveReason
    public var at: Date
    public var seen: Bool

    public init(id: Int64? = nil, reminderId: String, from: Date, to: Date, reason: MoveReason, at: Date, seen: Bool = false) {
        self.id = id
        self.reminderId = reminderId
        self.from = from
        self.to = to
        self.reason = reason
        self.at = at
        self.seen = seen
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Placement: Hashable, Sendable {
    public let reminderId: String
    public let from: Date
    public let to: Date

    public init(reminderId: String, from: Date, to: Date) {
        self.reminderId = reminderId
        self.from = from
        self.to = to
    }
}

/// A reminder that overlaps a busy interval it cannot leave.
public struct ScheduleConflict: Hashable, Sendable {
    public let reminderId: String
    public let interval: DateInterval

    public init(reminderId: String, interval: DateInterval) {
        self.reminderId = reminderId
        self.interval = interval
    }
}
