import Foundation

/// What a Claude Code session should hear from Tickler when it starts. Only text Tickler builds or the owner wrote.
public enum SessionDigest {
    static let maxLines = 8
    static let todayLink = "[open today in Tickler](tickler://view/today)"

    /// The context Claude reads, and a one-line summary shown to the owner in the terminal.
    public struct Digest: Equatable, Sendable {
        public let context: String
        public let summary: String
    }

    // swiftlint:disable:next function_parameter_count
    public static func text(
        reminders: [Reminder],
        sessionFolder: String,
        now: Date,
        calendar: Calendar,
        gitRoot: (String) -> String?,
        folderExists: (String) -> Bool
    ) -> String? {
        digest(
            reminders: reminders, sessionFolder: sessionFolder, now: now, calendar: calendar,
            gitRoot: gitRoot, folderExists: folderExists
        )?.context
    }

    // swiftlint:disable:next function_parameter_count
    public static func digest(
        reminders: [Reminder],
        sessionFolder: String,
        now: Date,
        calendar: Calendar,
        gitRoot: (String) -> String?,
        folderExists: (String) -> Bool
    ) -> Digest? {
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
        let mine = open.filter { canProduceOutput($0, now: now, calendar: calendar) && attached($0) }
        let groups = Groups(mine, now: now, calendar: calendar)
        let lines = groups.lines(now: now, calendar: calendar)
        let soon = now.addingTimeInterval(3600)
        let lateElsewhere = open.count { $0.dueAt < now && !attached($0) }
        let soonElsewhere = open.count { $0.dueAt >= now && $0.dueAt < soon && !attached($0) }
        let elsewhere = [
            lateElsewhere > 0 ? "\(lateElsewhere) overdue" : nil,
            soonElsewhere > 0 ? "\(soonElsewhere) due within the hour" : nil,
        ].compactMap(\.self).joined(separator: ", ")
        guard !lines.isEmpty || !elsewhere.isEmpty else { return nil }

        let name = title(((sessionRoot ?? folder) as NSString).lastPathComponent)
        var out: [String]
        if lines.isEmpty {
            out = [
                "Tickler (information only: do not act on it unless the user asks). "
                    + "Mention it in one line at the start of your first reply.",
            ]
        } else {
            out = [
                "Tickler reminders for \(name) (information only: do not act on them unless the user asks).",
                "Start your first reply with them as a short list: each item is its linked title exactly as below, never the reminder id.",
            ]
            out += lines.prefix(maxLines)
            if lines.count > maxLines {
                out.append("- and \(lines.count - maxLines) more: \(todayLink)")
            }
        }
        if !elsewhere.isEmpty {
            out.append("Other projects: \(elsewhere). \(todayLink)")
        }
        let here = groups.counts.isEmpty ? nil : "\(groups.counts) in \(name)"
        let away = elsewhere.isEmpty ? nil : "\(elsewhere) elsewhere"
        let summary = "Tickler: " + [here, away].compactMap(\.self).joined(separator: "; ")
        return Digest(context: out.joined(separator: "\n"), summary: summary)
    }

    /// The repository's reminders by section, each reminder in exactly one.
    struct Groups {
        let fired: [Reminder]
        let overdue: [Reminder]
        let today: [Reminder]
        let waiting: [Reminder]

        init(_ reminders: [Reminder], now: Date, calendar: Calendar) {
            let sorted = reminders.sorted { $0.dueAt < $1.dueAt }
            fired = sorted.filter { isFired($0, now: now) }
            let rest = sorted.filter { !isFired($0, now: now) }
            overdue = rest.filter { $0.dueAt < now }
            today = rest.filter { $0.dueAt >= now && calendar.isDate($0.dueAt, inSameDayAs: now) }
            waiting = rest.filter { DueBucket.of($0, now: now, calendar: calendar) == .waiting }
        }

        func lines(now: Date, calendar: Calendar) -> [String] {
            fired.map { line($0, "fired (\(title($0.firedReason ?? "")))") }
                + overdue.map { line($0, "overdue since \(when($0.dueAt, now: now, calendar: calendar))") }
                + today.map { line($0, "today \(when($0.dueAt, now: now, calendar: calendar))") }
                + waiting.map {
                    line($0, "waiting for \(title($0.trigger ?? "")), deadline \(when($0.dueAt, now: now, calendar: calendar))")
                }
        }

        /// "1 fired, 2 overdue, 4 today, 1 waiting", empty sections left out.
        var counts: String {
            [("fired", fired), ("overdue", overdue), ("today", today), ("waiting", waiting)]
                .filter { !$0.1.isEmpty }.map { "\($0.1.count) \($0.0)" }.joined(separator: ", ")
        }
    }

    /// Only these can show up in the digest, so only these are worth a git lookup.
    static func canProduceOutput(_ reminder: Reminder, now: Date, calendar: Calendar) -> Bool {
        reminder.dueAt < now || isFired(reminder, now: now) || calendar.isDate(reminder.dueAt, inSameDayAs: now)
            || DueBucket.of(reminder, now: now, calendar: calendar) == .waiting
    }

    static func isFired(_ reminder: Reminder, now: Date) -> Bool {
        reminder.firedReason != nil && reminder.firedAt == reminder.dueAt && reminder.dueAt <= now
    }

    /// The title carries the link: Claude repeats it as is, so the owner clicks a name, not an id.
    static func line(_ reminder: Reminder, _ label: String) -> String {
        "- \(label): [\(title(reminder.title))](tickler://open/\(reminder.id))"
    }

    /// One line, at most 100 characters, no control or format characters, no `[` `]` (so no markdown link).
    static func title(_ text: String) -> String {
        let joined = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let kept = joined.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
        var clean = String(String.UnicodeScalarView(kept))
        clean = clean.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        let line = clean.trimmingCharacters(in: .whitespaces)
        return line.count <= 100 ? line : String(line.prefix(99)) + "…"
    }

    /// "09:00" today, "Fri 9 Oct 09:30" otherwise; fixed English, as the context is for Claude.
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}
