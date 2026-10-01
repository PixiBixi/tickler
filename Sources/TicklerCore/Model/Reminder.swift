import Foundation
import GRDB

public struct Reminder: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reminder"

    public enum Status: String, Codable, Sendable, CaseIterable {
        case open
        case done
        case deleted
    }

    public enum Source: String, Codable, Sendable {
        case claude
        case human
    }

    public var id: String
    public var title: String
    public var notes: String
    public var dueAt: Date
    public var originalDueAt: Date
    public var rescheduleCount: Int
    public var status: Status
    public var sessionId: String?
    public var cwd: String?
    /// Sent to Claude when the session is resumed, as its first message.
    public var resumePrompt: String?
    public var source: Source
    public var externalRef: String?
    public var notifiedAt: Date?
    public var doneAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    /// Last path component of the session folder, "~" for the home folder itself.
    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let path = (cwd as NSString).standardizingPath
        if path == NSHomeDirectory() || path == "~" {
            return "~"
        }
        return (path as NSString).lastPathComponent
    }
}

/// What a caller provides to create a reminder; the store fills ids and timestamps.
public struct ReminderDraft: Sendable {
    public var title: String
    public var notes: String
    public var dueAt: Date
    public var links: [String]
    public var sessionId: String?
    public var cwd: String?
    public var resumePrompt: String?
    public var source: Reminder.Source
    public var externalRef: String?

    public init(
        title: String,
        notes: String = "",
        dueAt: Date,
        links: [String] = [],
        sessionId: String? = nil,
        cwd: String? = nil,
        resumePrompt: String? = nil,
        source: Reminder.Source = .claude,
        externalRef: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.links = links
        self.sessionId = sessionId
        self.cwd = cwd
        self.resumePrompt = resumePrompt
        self.source = source
        self.externalRef = externalRef
    }
}

public struct ReminderFilter: Sendable, Equatable {
    public enum Due: String, Sendable, CaseIterable {
        /// Due before the end of today, overdue included.
        case today
        /// Due within the next 7 days, overdue included.
        case week
        case overdue
        case all
    }

    public var due: Due
    public var status: Reminder.Status
    public var project: String?

    public init(due: Due = .all, status: Reminder.Status = .open, project: String? = nil) {
        self.due = due
        self.status = status
        self.project = project
    }
}

public enum ReminderID {
    /// No 0/o, 1/l/i: ids get typed by hand.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    public static func generate() -> String {
        String((0 ..< 6).map { _ in alphabet.randomElement()! })
    }
}
