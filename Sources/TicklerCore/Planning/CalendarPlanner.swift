import CryptoKit
import Foundation
import GRDB

/// Which calendar event mirrors which reminder, as last written by the app.
public struct CalendarMapping: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "calendarEvent"

    public var reminderId: String
    public var eventIdentifier: String
    public var calendarId: String
    public var syncedHash: String

    public init(reminderId: String, eventIdentifier: String, calendarId: String, syncedHash: String) {
        self.reminderId = reminderId
        self.eventIdentifier = eventIdentifier
        self.calendarId = calendarId
        self.syncedHash = syncedHash
    }
}

public enum CalendarAction: Hashable, Sendable {
    case create(Reminder, hash: String)
    case update(Reminder, eventIdentifier: String, hash: String)
    case delete(eventIdentifier: String, reminderId: String)
}

/// One-way sync plan: the app is the source of truth, the calendar is a view of it.
public enum CalendarPlanner {
    public static let pastWindow: TimeInterval = 7 * 86400
    public static let futureWindow: TimeInterval = 60 * 86400

    public static func contentHash(_ reminder: Reminder, links: [ReminderLink]) -> String {
        let parts = [reminder.title, reminder.notes, String(Int(reminder.dueAt.timeIntervalSince1970))] + links.map(\.url)
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `reminders` must hold every open reminder plus every reminder a mapping points at.
    public static func plan(
        reminders: [Reminder],
        links: [String: [ReminderLink]],
        mappings: [CalendarMapping],
        calendarId: String,
        now: Date
    ) -> [CalendarAction] {
        let byId = Dictionary(reminders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let window = now.addingTimeInterval(-pastWindow) ... now.addingTimeInterval(futureWindow)
        func wanted(_ reminder: Reminder) -> Bool {
            reminder.status == .open && window.contains(reminder.dueAt)
        }

        var actions: [CalendarAction] = []
        var mapped: [String: CalendarMapping] = [:]
        for mapping in mappings.sorted(by: { $0.reminderId < $1.reminderId }) {
            guard let reminder = byId[mapping.reminderId], wanted(reminder), mapping.calendarId == calendarId else {
                actions.append(.delete(eventIdentifier: mapping.eventIdentifier, reminderId: mapping.reminderId))
                continue
            }
            mapped[mapping.reminderId] = mapping
        }
        for reminder in reminders.filter(wanted).sorted(by: { $0.dueAt < $1.dueAt }) {
            let hash = contentHash(reminder, links: links[reminder.id] ?? [])
            if let mapping = mapped[reminder.id] {
                if mapping.syncedHash != hash {
                    actions.append(.update(reminder, eventIdentifier: mapping.eventIdentifier, hash: hash))
                }
            } else {
                actions.append(.create(reminder, hash: hash))
            }
        }
        return actions
    }
}
