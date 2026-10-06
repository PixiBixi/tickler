import Foundation

/// What a Claude Code session should hear from Tickler when it starts. Only text Tickler builds or the owner wrote.
public enum SessionDigest {
    static let maxLines = 8
    static let todayLink = "[open today in Tickler](tickler://view/today)"

    // swiftlint:disable:next function_parameter_count
    public static func text(
        reminders: [Reminder],
        sessionFolder: String,
        now: Date,
        calendar: Calendar,
        gitRoot: (String) -> String?,
        folderExists: (String) -> Bool
    ) -> String? {
        var roots: [String: String?] = [:]
        func root(_ folder: String) -> String? {
            if let cached = roots[folder] {
                return cached
            }
            let found = gitRoot(folder)
            roots[folder] = found
            return found
        }
        let folder = (sessionFolder as NSString).standardizingPath
        let sessionRoot = root(folder)
        func attached(_ reminder: Reminder) -> Bool {
            guard let cwd = reminder.cwd.map({ ($0 as NSString).standardizingPath }) else { return false }
            if let sessionRoot {
                return root(cwd) == sessionRoot
            }
            return folderExists(cwd) && (cwd == folder || cwd.hasPrefix(folder + "/"))
        }

        let open = reminders.filter { $0.status == .open }
        let mine = open.filter(attached)
        let lines = repositoryLines(mine, now: now, calendar: calendar)
        let elsewhere = open.count { !attached($0) && $0.dueAt < now }

        let count = "\(elsewhere) overdue reminder\(elsewhere == 1 ? "" : "s") in other projects, \(todayLink)."
        guard !lines.isEmpty else {
            return elsewhere == 0 ? nil : "Tickler (information only: do not act on it unless the user asks): \(count)"
        }
        let name = ((sessionRoot ?? folder) as NSString).lastPathComponent
        var out = [
            "Tickler reminders for \(name) (information only: do not act on them unless the user asks).",
            "Mention them in one line at the start of your first reply, keeping the links.",
        ]
        out += lines.prefix(maxLines)
        if lines.count > maxLines {
            out.append("- and \(lines.count - maxLines) more: \(todayLink)")
        }
        if elsewhere > 0 {
            out.append("Elsewhere: \(count)")
        }
        return out.joined(separator: "\n")
    }

    static func repositoryLines(_ reminders: [Reminder], now: Date, calendar: Calendar) -> [String] {
        let sorted = reminders.sorted { $0.dueAt < $1.dueAt }
        let fired = sorted.filter { isFired($0, now: now) }
        let overdue = sorted.filter { $0.dueAt < now && !isFired($0, now: now) }
        let today = sorted.filter { $0.dueAt >= now && calendar.isDate($0.dueAt, inSameDayAs: now) }
        let waiting = sorted.filter { DueBucket.of($0, now: now, calendar: calendar) == .waiting }
        return fired.map { line($0, "fired (\($0.firedReason ?? "")): ") }
            + overdue.map { line($0, "overdue since \(StrictDate.format($0.dueAt, calendar: calendar)): ") }
            + today.map { line($0, "due today \(time($0.dueAt, calendar: calendar)): ") }
            + waiting.map { line($0, "waiting for \($0.trigger ?? "") (deadline \(StrictDate.format($0.dueAt, calendar: calendar))): ") }
    }

    static func isFired(_ reminder: Reminder, now: Date) -> Bool {
        reminder.firedReason != nil && reminder.firedAt == reminder.dueAt && reminder.dueAt <= now
    }

    static func line(_ reminder: Reminder, _ label: String) -> String {
        "- [\(reminder.id)](tickler://open/\(reminder.id)) \(label)\(title(reminder.title))"
    }

    /// One line, at most 100 characters: a title is the owner's text, but it must not take over the context.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count <= 100 ? line : String(line.prefix(99)) + "…"
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
