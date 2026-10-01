import Foundation
import TicklerCore

/// `tickler show` in a terminal: title, due date in context, notes with their Markdown applied, links that open,
/// and the session with the command to resume it. Pipes keep the plain key: value output.
struct ReminderCard {
    let now: Date
    let calendar: Calendar
    let width: Int
    let sessionRunning: Bool?

    func render(_ reminder: Reminder, links: [ReminderLink]) -> String {
        var lines: [String] = []
        lines.append(Ansi.style(reminder.title, .bold))
        lines.append(dueLine(reminder))
        if let cwd = reminder.cwd {
            lines.append(Ansi.style(abbreviate(cwd), .dim))
        }

        if !reminder.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", Ansi.style("Notes", .heading)]
            lines += MarkdownNotes.blocks(from: reminder.notes).map(render)
        }

        if !links.isEmpty {
            lines += ["", Ansi.style("Links", .heading)]
            let kindWidth = links.map { kindName($0.kind).count }.max() ?? 0
            for link in links {
                let kind = kindName(link.kind).padding(toLength: kindWidth, withPad: " ", startingAt: 0)
                lines.append("  \(Ansi.style(kind, .dim))  \(Ansi.link(Ansi.style(link.label, .underline), to: link.url))")
            }
        }

        if let session = reminder.sessionId {
            lines += ["", Ansi.style("Claude session", .heading)]
            let state = switch sessionRunning {
            case true?: Ansi.style("● running", .green)
            case false?: Ansi.style("○ ended", .dim)
            case nil: ""
            }
            lines.append("  \(state)  \(Ansi.style(session, .dim))")
            if let prompt = reminder.resumePrompt {
                lines.append("  says \(Ansi.style("\u{201C}\(prompt)\u{201D}", .bold)) on resume")
            }
            lines.append("  \(Ansi.style("tickler resume \(reminder.id)", .accent))")
        }

        lines += ["", footer(reminder)]
        return lines.joined(separator: "\n")
    }

    private func dueLine(_ reminder: Reminder) -> String {
        let when = StrictDate.format(reminder.dueAt, calendar: calendar)
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "en_GB")
        relative.unitsStyle = .full
        let distance = relative.localizedString(for: reminder.dueAt, relativeTo: now)
        let bucket = DueBucket.of(reminder.dueAt, now: now, calendar: calendar)
        var parts: [String] = []
        switch reminder.status {
        case .done: parts.append(Ansi.style("done", .green))
        case .deleted: parts.append(Ansi.style("deleted", .red))
        case .open: parts.append(bucket == .overdue ? Ansi.style("overdue", .redBold) : Ansi.style("open", .dim))
        }
        let style: Ansi.Style = reminder.status == .open && bucket == .overdue ? .red : (bucket == .today ? .accent : .plain)
        parts.append(Ansi.style("\(when) (\(distance))", style))
        if let project = reminder.project {
            parts.append(Ansi.style(project, .dim))
        }
        return parts.joined(separator: Ansi.style("  ·  ", .dim))
    }

    private func footer(_ reminder: Reminder) -> String {
        var parts = [Ansi.link(Ansi.style(reminder.id, .accent), to: CalendarMarker.link(for: reminder.id))]
        parts
            .append(
                "added \(StrictDate.format(reminder.createdAt, calendar: calendar)) by \(reminder.source == .claude ? "Claude" : "you")"
            )
        if reminder.rescheduleCount > 0 {
            parts
                .append(
                    "rescheduled \(reminder.rescheduleCount)× (first due \(StrictDate.format(reminder.originalDueAt, calendar: calendar)))"
                )
        }
        return Ansi.style(parts.joined(separator: "  ·  "), .dim)
    }

    // MARK: Notes

    private func render(_ block: MarkdownNotes.Block) -> String {
        switch block {
        case let .heading(_, text): "  " + Ansi.style(inline(text), .bold)
        case let .bullet(text, depth): "  " + String(repeating: "  ", count: depth) + Ansi.style("-", .dim) + " " + inline(text)
        case let .numbered(marker, text): "  " + Ansi.style(marker, .dim) + " " + inline(text)
        case let .code(code): code.components(separatedBy: "\n").map { "    " + Ansi.style($0, .code) }.joined(separator: "\n")
        case let .quote(text): "  " + Ansi.style("│ " + inline(text), .dim)
        case let .paragraph(text): "  " + inline(text)
        case .spacer: ""
        }
    }

    /// **bold**, *italic*, `code` and [label](url) as terminal styles; bare URLs first get their short name.
    private func inline(_ text: String) -> String {
        var output = MarkdownNotes.autolink(text)
        output = output.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { match in
            Ansi.link(Ansi.style(String(match.1), .underline), to: String(match.2))
        }
        output = output.replacing(/\*\*([^*]+)\*\*/) { Ansi.style(String($0.1), .bold) }
        output = output.replacing(/`([^`]+)`/) { Ansi.style(String($0.1), .code) }
        output = output.replacing(/(^|[\s(])\*([^*\s][^*]*)\*(?=$|[\s.,;:)!?])/) { String($0.1) + Ansi.style(String($0.2), .italic) }
        return output
    }

    private func kindName(_ kind: LinkKind) -> String {
        switch kind {
        case .gitlabMR: "MR"
        case .githubPR: "PR"
        case .jira: "Jira"
        case .grafana: "Grafana"
        case .slack: "Slack"
        case .other: "Link"
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Terminal escapes shared by the table and the card.
enum Ansi {
    enum Style {
        case plain, bold, dim, red, redBold, green, accent, strike, heading, underline, italic, code

        var code: String {
            switch self {
            case .plain: ""
            case .bold: "1"
            case .dim: "2"
            case .red: "31"
            case .redBold: "1;31"
            case .green: "32"
            case .accent: "38;5;173"
            case .strike: "2;9"
            case .heading: "1;38;5;173"
            case .underline: "4"
            case .italic: "3"
            case .code: "36"
            }
        }
    }

    static func style(_ text: String, _ style: Style) -> String {
        guard !style.code.isEmpty, !text.isEmpty else { return text }
        return "\u{1B}[\(style.code)m\(text)\u{1B}[0m"
    }

    /// OSC 8 hyperlink: ⌘-click in WezTerm, Ghostty and iTerm2.
    static func link(_ text: String, to url: String) -> String {
        "\u{1B}]8;;\(url)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\"
    }
}
