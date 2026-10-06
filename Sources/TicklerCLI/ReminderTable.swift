import Foundation
import TicklerCore

/// `tickler list` in a terminal: sections by due bucket, aligned columns, colors, and ids that open the app
/// (OSC 8 hyperlinks to tickler://open/<id>). Pipes and Claude keep the plain one-line-per-reminder output.
struct ReminderTable {
    let now: Date
    let calendar: Calendar
    let width: Int
    let color: Bool

    func render(_ reminders: [Reminder]) -> String {
        guard !reminders.isEmpty else { return style("No reminders.", .dim) }
        let groups = Dictionary(grouping: reminders) { reminder -> DueBucket? in
            reminder.status == .done ? nil : DueBucket.of(reminder, now: now, calendar: calendar)
        }
        let order: [DueBucket?] = [.overdue, .today, .tomorrow, .later, .waiting, nil]
        let dueWidth = reminders.map { due($0).count }.max() ?? 0
        let projectWidth = min(reminders.map { ($0.project ?? "").count }.max() ?? 0, 24)
        // id (6) + gaps (3 x 2) + due + project: the title gets what is left, never less than 20.
        let titleWidth = max(20, width - 6 - 6 - dueWidth - projectWidth - 2)
        var lines: [String] = []
        for bucket in order {
            guard let items = groups[bucket], !items.isEmpty else { continue }
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(style("\(title(bucket)) (\(items.count))", bucket == .overdue ? .redBold : .bold))
            for reminder in items {
                let dueText = pad(due(reminder), dueWidth)
                let dimmed = bucket == .later || bucket == .waiting || bucket == nil
                let dueStyle: Ansi.Style = bucket == .overdue ? .red : (dimmed ? .dim : .plain)
                let titleText = pad(truncate(reminder.title, titleWidth), titleWidth)
                lines.append([
                    link(style(reminder.id, .accent), to: CalendarMarker.link(for: reminder.id)),
                    style(dueText, dueStyle),
                    reminder.status == .done ? style(titleText, .strike) : titleText,
                    style(truncate(reminder.project ?? "", projectWidth), .dim),
                ].joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func title(_ bucket: DueBucket?) -> String {
        switch bucket {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .later: "Later"
        case .waiting: "Waiting"
        case nil: "Done"
        }
    }

    /// "09:30" today and tomorrow (the section says which day), "Mon 5 Oct 10:30" beyond, the date for overdue ones.
    private func due(_ reminder: Reminder) -> String {
        switch DueBucket.of(reminder.dueAt, now: now, calendar: calendar) {
        case .today, .tomorrow: format(reminder.dueAt, "HH:mm")
        case .overdue where calendar.isDate(reminder.dueAt, inSameDayAs: now): format(reminder.dueAt, "HH:mm")
        default: format(reminder.dueAt, "EEE d MMM HH:mm")
        }
    }

    /// Fixed 24 h English format in the calendar's time zone: the CLI is English, and columns must line up.
    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(max(limit - 1, 0))) + "…"
    }

    private func pad(_ text: String, _ length: Int) -> String {
        text.count >= length ? text : text + String(repeating: " ", count: length - text.count)
    }

    // MARK: Terminal escapes

    private func style(_ text: String, _ style: Ansi.Style) -> String {
        color ? Ansi.style(text, style) : text
    }

    private func link(_ text: String, to url: String) -> String {
        color ? Ansi.link(text, to: url) : text
    }
}

enum Terminal {
    static var isInteractive: Bool {
        isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    static var width: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100
    }
}
