import Foundation
import TicklerCore

/// The `--json` shape of a reminder, stable for scripts and for Claude. Keys are sorted; absent values are `null`.
///
/// `id`, `title`, `notes`, `due` ("YYYY-MM-DD HH:MM", local), `dueISO` (ISO 8601 with UTC offset), `originalDue`,
/// `rescheduleCount`, `status` (open|done|deleted), `source` (claude|human), `sessionId`, `cwd`, `project`,
/// `overdue` (open and past due), `links` (`[{kind, label, url}]`).
struct ReminderJSON: Encodable {
    struct Link: Encodable {
        let kind: String
        let label: String
        let url: String
    }

    let id: String
    let title: String
    let notes: String
    let due: String
    let dueISO: String
    let originalDue: String
    let rescheduleCount: Int
    let status: String
    let source: String
    let sessionId: String?
    let cwd: String?
    let project: String?
    let overdue: Bool
    let links: [Link]

    init(_ reminder: Reminder, links: [ReminderLink], context: CLIContext) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = context.calendar.timeZone
        id = reminder.id
        title = reminder.title
        notes = reminder.notes
        due = StrictDate.format(reminder.dueAt, calendar: context.calendar)
        dueISO = formatter.string(from: reminder.dueAt)
        originalDue = StrictDate.format(reminder.originalDueAt, calendar: context.calendar)
        rescheduleCount = reminder.rescheduleCount
        status = reminder.status.rawValue
        source = reminder.source.rawValue
        sessionId = reminder.sessionId
        cwd = reminder.cwd
        project = reminder.project
        overdue = reminder.status == .open && reminder.dueAt < context.now()
        self.links = links.map { Link(kind: $0.kind.rawValue, label: $0.label, url: $0.url) }
    }

    /// Explicit so that nil values are written as null instead of dropped.
    func encode(to encoder: Encoder) throws {
        enum Key: String, CodingKey {
            case id, title, notes, due, dueISO, originalDue, rescheduleCount, status, source
            case sessionId, cwd, project, overdue, links
        }
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(notes, forKey: .notes)
        try container.encode(due, forKey: .due)
        try container.encode(dueISO, forKey: .dueISO)
        try container.encode(originalDue, forKey: .originalDue)
        try container.encode(rescheduleCount, forKey: .rescheduleCount)
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(project, forKey: .project)
        try container.encode(overdue, forKey: .overdue)
        try container.encode(links, forKey: .links)
    }
}

extension CLIContext {
    func encodeJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    func json(_ reminder: Reminder, store: ReminderStore) throws -> ReminderJSON {
        try ReminderJSON(reminder, links: store.links(for: reminder.id), context: self)
    }

    func summaryLine(_ reminder: Reminder) -> String {
        "\(reminder.id)\t\(reminder.title)\t\(StrictDate.format(reminder.dueAt, calendar: calendar))"
    }

    func listLine(_ reminder: Reminder) -> String {
        var line = "\(reminder.id)  \(StrictDate.format(reminder.dueAt, calendar: calendar))  \(reminder.title)"
        if let project = reminder.project {
            line += "  [\(project)]"
        }
        if reminder.status == .open, reminder.dueAt < now() {
            line += "  OVERDUE"
        }
        return line
    }

    /// Prints the reminder as JSON or as its summary line: what every mutating command answers.
    func printResult(_ reminder: Reminder, store: ReminderStore, json: Bool) throws {
        if json {
            try stdout.line(encodeJSON(self.json(reminder, store: store)))
        } else {
            stdout.line(summaryLine(reminder))
        }
    }

    func detail(_ reminder: Reminder, links: [ReminderLink]) -> String {
        var lines = [
            "id: \(reminder.id)",
            "title: \(reminder.title)",
            "due: \(StrictDate.format(reminder.dueAt, calendar: calendar))"
                + (reminder.status == .open && reminder.dueAt < now() ? " (OVERDUE)" : ""),
            "status: \(reminder.status.rawValue)",
            "source: \(reminder.source.rawValue)",
            "rescheduled: \(reminder.rescheduleCount) (originally \(StrictDate.format(reminder.originalDueAt, calendar: calendar)))",
        ]
        if let project = reminder.project {
            lines.append("project: \(project)")
        }
        if let cwd = reminder.cwd {
            lines.append("cwd: \(cwd)")
        }
        if let session = reminder.sessionId {
            lines.append("session: \(session)")
        }
        if !reminder.notes.isEmpty {
            lines.append("notes:")
            lines += reminder.notes.components(separatedBy: "\n").map { "  \($0)" }
        }
        if !links.isEmpty {
            lines.append("links:")
            lines += links.map { "  \($0.kind.rawValue) \($0.label) \($0.url)" }
        }
        if reminder.sessionId != nil {
            lines.append("resume: tickler resume \(reminder.id)")
        }
        return lines.joined(separator: "\n")
    }
}
