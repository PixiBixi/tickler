import Foundation

/// The notification action set of a reminder. Categories are static in UserNotifications,
/// so each combination of "has a ticket" and "has a Slack thread or another link" is its own category.
public enum NotificationCategory: String, CaseIterable, Sendable {
    case plain = "reminder.none.none"
    case slack = "reminder.none.slack"
    case link = "reminder.none.link"
    case ticket = "reminder.ticket.none"
    case ticketSlack = "reminder.ticket.slack"
    case ticketLink = "reminder.ticket.link"

    public static let summaryIdentifier = "reminder.summary"
    /// "Claude added a reminder" banners: informational, never tied to a due time.
    public static let announcementPrefix = "tickler.new"

    public var hasTicket: Bool {
        self == .ticket || self == .ticketSlack || self == .ticketLink
    }

    public var hasSlack: Bool {
        self == .slack || self == .ticketSlack
    }

    public var hasLink: Bool {
        self == .link || self == .ticketLink
    }

    public static func `for`(links: [ReminderLink]) -> NotificationCategory {
        let targets = LinkTargets(links: links)
        switch (targets.ticket != nil, targets.slack != nil, targets.other != nil) {
        case (true, true, _): return .ticketSlack
        case (true, false, true): return .ticketLink
        case (true, false, false): return .ticket
        case (false, true, _): return .slack
        case (false, false, true): return .link
        case (false, false, false): return .plain
        }
    }
}

/// Which link each "Open" action opens: the first Jira ticket, the first Slack thread,
/// and the first remaining link, the last one only offered when there is no Slack thread.
public struct LinkTargets: Sendable {
    public let ticket: ReminderLink?
    public let slack: ReminderLink?
    public let other: ReminderLink?

    public init(links: [ReminderLink]) {
        let sorted = links.sorted { $0.position < $1.position }
        ticket = sorted.first { $0.kind == .jira }
        slack = sorted.first { $0.kind == .slack }
        other = slack == nil ? sorted.first { $0.kind != .jira && $0.kind != .slack } : nil
    }
}

public struct PlannedNotification: Hashable, Sendable {
    public let id: String
    public let reminder: Reminder
    public let category: NotificationCategory
}

public enum CatchUp: Equatable, Sendable {
    case none
    case individual([Reminder])
    case summary([Reminder])
    /// A summary plus one notification each for the freshly fired ones, whose reason a summary would drop.
    case summaryAndIndividual(summary: [Reminder], individual: [Reminder])
}

/// Decides which notification requests should exist; the app applies the difference to UNUserNotificationCenter.
public enum NotificationPlanner {
    /// macOS keeps at most 64 pending requests per app.
    public static let pendingLimit = 64
    public static let individualCatchUpLimit = 3

    /// `<id>@<trigger tag>@<due epoch>`: changes with the due date and the trigger, so a rescheduled or re-armed reminder
    /// gets a fresh request instead of a stale one.
    public static func requestId(for reminder: Reminder) -> String {
        "\(reminder.id)@\(triggerTag(reminder.trigger))@\(Int(reminder.dueAt.timeIntervalSince1970))"
    }

    /// "-" without a trigger, else a stable FNV-1a hash of it (`hashValue` changes per launch).
    private static func triggerTag(_ trigger: String?) -> String {
        guard let trigger else { return "-" }
        let hash = trigger.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return String(hash, radix: 16)
    }

    public static func reminderId(fromRequestId requestId: String) -> String {
        String(requestId.split(separator: "@").first ?? Substring(requestId))
    }

    public static func plan(
        reminders: [Reminder],
        links: [String: [ReminderLink]],
        pendingIds: Set<String>,
        now: Date,
        limit: Int = pendingLimit
    ) -> (add: [PlannedNotification], remove: [String]) {
        let wanted = reminders
            .filter { $0.status == .open && $0.dueAt > now }
            .sorted { $0.dueAt < $1.dueAt }
            .prefix(limit)
            .map { PlannedNotification(id: requestId(for: $0), reminder: $0, category: .for(links: links[$0.id] ?? [])) }
        // A pending request already past due is about to fire (Mac waking up): keep it while it still matches its reminder.
        let current = Set(reminders.filter { $0.status == .open }.map(requestId(for:)))
        let keep = Set(wanted.map(\.id)).union(pendingIds.filter { current.contains($0) && !isFuture($0, now: now) })
        return (
            add: wanted.filter { !pendingIds.contains($0.id) },
            remove: pendingIds.subtracting(keep).sorted()
        )
    }

    /// Delivered banners that no longer match an open reminder at its current time: done, deleted or rescheduled.
    public static func staleDelivered(deliveredIds: [String], reminders: [Reminder]) -> [String] {
        let current = Set(reminders.filter { $0.status == .open }.map(requestId(for:)))
        return deliveredIds.filter {
            !$0.hasPrefix(NotificationCategory.summaryIdentifier) && !$0.hasPrefix(NotificationCategory.announcementPrefix) && !current
                .contains($0)
        }
    }

    /// Reminders that appeared since the last look, added outside the app (Claude or the CLI): what the banner announces.
    public static func newlyAdded(previousIds: Set<String>, reminders: [Reminder]) -> [Reminder] {
        reminders.filter { $0.status == .open && !previousIds.contains($0.id) }
    }

    /// Whether a notification response still speaks for the reminder as it is now.
    public static func isCurrent(requestId: String, reminder: Reminder) -> Bool {
        reminder.status == .open && requestId == self.requestId(for: reminder)
    }

    private static func isFuture(_ requestId: String, now: Date) -> Bool {
        guard let epoch = requestId.split(separator: "@").last.flatMap({ Double($0) }) else { return false }
        return epoch > now.timeIntervalSince1970
    }

    /// Overdue reminders nobody was told about (Mac asleep or app not running at due time).
    /// `alreadyShownIds` holds pending and delivered request ids: those fire or already fired on their own.
    public static func catchUp(reminders: [Reminder], alreadyShownIds: Set<String>, now: Date) -> CatchUp {
        let missed = reminders
            .filter { $0.status == .open && $0.dueAt <= now && $0.notifiedAt == nil && !alreadyShownIds.contains(requestId(for: $0)) }
            .sorted { $0.dueAt < $1.dueAt }
        if missed.isEmpty {
            return .none
        }
        // A freshly fired reminder carries its reason, which a summary would drop: it always gets its own notification.
        let fired = missed.filter { $0.firedAt != nil && $0.firedAt == $0.dueAt }
        let rest = missed.filter { !fired.contains($0) }
        if rest.count <= individualCatchUpLimit {
            return .individual(missed)
        }
        return fired.isEmpty ? .summary(rest) : .summaryAndIndividual(summary: rest, individual: fired)
    }
}
