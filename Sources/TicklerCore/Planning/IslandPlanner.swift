import Foundation

/// What the pill near the notch shows, and when that next changes.
public struct IslandPlan: Equatable, Sendable {
    /// nil: hide the pill.
    public var shown: Reminder?
    /// The "+N" badge: other reminders in the same window.
    public var othersInWindow: Int
    /// When to plan again; nil when no reminder can ever show.
    public var nextChange: Date?

    public init(shown: Reminder?, othersInWindow: Int, nextChange: Date?) {
        self.shown = shown
        self.othersInWindow = othersInWindow
        self.nextChange = nextChange
    }
}

public enum IslandPlanner {
    /// A reminder stays as "now" this long after its due date; older ones are left to the notifications.
    public static let grace: TimeInterval = 5 * 60
    public static let leadRange: ClosedRange<TimeInterval> = 60 ... 120 * 60

    public static func plan(open: [Reminder], now: Date, lead: TimeInterval) -> IslandPlan {
        let lead = min(max(lead, leadRange.lowerBound), leadRange.upperBound)
        // A waiting reminder's due date is only its fallback deadline; an auto-run one needs no action at its due time,
        // its result notification is the signal.
        let candidates = open
            .filter { $0.status == .open && !$0.isWaiting && $0.autoRun == nil && $0.dueAt >= now.addingTimeInterval(-grace) }
            .sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
        let inWindow = candidates.filter { $0.dueAt <= now.addingTimeInterval(lead) }
        let entries = candidates.lazy.filter { $0.dueAt > now.addingTimeInterval(lead) }.map { $0.dueAt.addingTimeInterval(-lead) }
        let exits = inWindow.map { $0.dueAt.addingTimeInterval(grace) }
        return IslandPlan(
            shown: inWindow.first,
            othersInWindow: max(inWindow.count - 1, 0),
            nextChange: (exits + entries.prefix(1)).min()
        )
    }
}
