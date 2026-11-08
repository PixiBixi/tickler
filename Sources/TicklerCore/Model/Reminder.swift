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
    /// The event that makes it due now, as typed (`merged`, `jira:In Review`); nil once fired.
    public var trigger: String? = nil // swiftlint:disable:this implicit_optional_initialization
    public var firedAt: Date? = nil // swiftlint:disable:this implicit_optional_initialization
    /// Why the trigger fired, built from the live data: `!412 merged`.
    public var firedReason: String? = nil // swiftlint:disable:this implicit_optional_initialization

    /// Raw `AutoRunMode`: when set, the resume prompt runs in the background once due.
    public var autoRun: String? = nil // swiftlint:disable:this implicit_optional_initialization
    /// Resume starts a new session in `cwd` with the resume message instead of reopening `sessionId`.
    public var fresh: Bool = false
    /// Planner footprint in minutes.
    public var durationMinutes: Int = 15
    /// Pinned by the user: the planner never moves it.
    public var fixed: Bool = false
    /// The planner never places it earlier than this.
    public var notBefore: Date? = nil // swiftlint:disable:this implicit_optional_initialization
    public var deadline: Date? = nil // swiftlint:disable:this implicit_optional_initialization

    /// The planner must leave it where it is.
    public var holdsItsTime: Bool {
        fixed || autoRun != nil || firedAt != nil
    }

    public var earliestStart: Date {
        notBefore ?? dueAt
    }

    public var isLate: Bool {
        deadline.map { dueAt > $0 } ?? false
    }

    public var autoRunMode: AutoRunMode? {
        autoRun.flatMap(AutoRunMode.init)
    }

    /// The session a resume or a background run continues: none when it starts fresh.
    public var continuedSessionId: String? {
        fresh ? nil : sessionId
    }

    /// Resume has something to do: reopen the session, or start a fresh one in the folder.
    public var canResume: Bool {
        fresh ? cwd?.isEmpty == false : sessionId != nil
    }

    public var parsedTrigger: Trigger? {
        trigger.flatMap(Trigger.init)
    }

    /// Open and still waiting for its event.
    public var isWaiting: Bool {
        status == .open && trigger != nil
    }

    /// What Resume sends: the reason the trigger fired, then the resume prompt.
    public var resumeMessage: String? {
        guard let firedReason else { return resumePrompt }
        guard let resumePrompt else { return firedReason }
        return "\(firedReason). \(resumePrompt)"
    }

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
    public var trigger: Trigger?
    public var autoRun: AutoRunMode?
    public var fresh: Bool
    public var durationMinutes: Int
    public var fixed: Bool
    public var notBefore: Date?
    public var deadline: Date?

    public init(
        title: String,
        notes: String = "",
        dueAt: Date,
        links: [String] = [],
        sessionId: String? = nil,
        cwd: String? = nil,
        resumePrompt: String? = nil,
        source: Reminder.Source = .claude,
        externalRef: String? = nil,
        trigger: Trigger? = nil,
        autoRun: AutoRunMode? = nil,
        fresh: Bool = false,
        durationMinutes: Int = 15,
        fixed: Bool = false,
        notBefore: Date? = nil,
        deadline: Date? = nil
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
        self.trigger = trigger
        self.autoRun = autoRun
        self.fresh = fresh
        self.durationMinutes = durationMinutes
        self.fixed = fixed
        self.notBefore = notBefore
        self.deadline = deadline
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
