import Foundation

/// Tags an event with the reminder it mirrors, in its URL and on the last line of its notes, so the app finds
/// the event again when the stored identifier went stale (CalDAV servers such as Google may change it).
public enum CalendarMarker {
    public static func link(for reminderId: String) -> String {
        "\(Tickler.urlScheme)://open/\(reminderId)"
    }

    public static func reminderId(url: URL?, notes: String?) -> String? {
        if let url, url.scheme == Tickler.urlScheme, url.host() == "open", let id = url.pathComponents.last, id != "/" {
            return id
        }
        let prefix = "\(Tickler.urlScheme)://open/"
        guard let last = notes?.split(whereSeparator: \.isNewline).last, last.hasPrefix(prefix) else { return nil }
        let id = last.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// Events by the reminder their marker names, first one kept: one scan per sync run, not one per event (#25).
    public static func index<Event>(_ events: [Event], marker: (Event) -> (url: URL?, notes: String?)) -> [String: Event] {
        var byReminder: [String: Event] = [:]
        for event in events {
            let (url, notes) = marker(event)
            if let id = reminderId(url: url, notes: notes), byReminder[id] == nil {
                byReminder[id] = event
            }
        }
        return byReminder
    }

    /// The notes written to the event:the reminder notes, its links, then the marker line.
    public static func notes(for reminder: Reminder, links: [ReminderLink]) -> String {
        var blocks = [reminder.notes.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !links.isEmpty {
            blocks.append(links.map { "\($0.label): \($0.url)" }.joined(separator: "\n"))
        }
        blocks.append(link(for: reminder.id))
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
