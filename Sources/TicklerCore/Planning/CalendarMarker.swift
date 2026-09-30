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

    /// The notes written to the event: the reminder notes, its links, then the marker line.
    public static func notes(for reminder: Reminder, links: [ReminderLink]) -> String {
        var blocks = [reminder.notes.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !links.isEmpty {
            blocks.append(links.map { "\($0.label): \($0.url)" }.joined(separator: "\n"))
        }
        blocks.append(link(for: reminder.id))
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
