import Foundation

public enum AutoRunDecision: Equatable, Sendable {
    case start(Reminder)
    case skip(Reminder)
}

/// Decides which due auto-run reminders start a background run; pure, the app applies the result.
public enum AutoRunPlanner {
    /// A run counts for a due date whatever its outcome: a failed or cancelled run is not retried on its own.
    public static func hasRun(_ reminder: Reminder, lastRun: AutoRun?) -> Bool {
        guard let lastRun else { return false }
        return lastRun.state == .running || lastRun.forDueAt == reminder.dueAt
    }

    public static func decide(
        reminders: [Reminder],
        lastRuns: [String: AutoRun],
        terminalSessions: Set<String>,
        autoRunSessions: Set<String>,
        now: Date
    ) -> [AutoRunDecision] {
        let candidates = reminders
            .filter { isCandidate($0, lastRuns: lastRuns) && $0.dueAt <= now }
            .sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
        var claimed = Set<String>()
        var decisions: [AutoRunDecision] = []
        for reminder in candidates {
            guard let session = reminder.sessionId else {
                decisions.append(.start(reminder))
                continue
            }
            if autoRunSessions.contains(session) || claimed.contains(session) {
                continue
            }
            if terminalSessions.contains(session) {
                decisions.append(.skip(reminder))
            } else {
                decisions.append(.start(reminder))
            }
            claimed.insert(session)
        }
        return decisions
    }

    /// The earliest future due date that still has a run to start.
    public static func nextDue(reminders: [Reminder], lastRuns: [String: AutoRun], now: Date) -> Date? {
        reminders
            .filter { isCandidate($0, lastRuns: lastRuns) && $0.dueAt > now }
            .map(\.dueAt)
            .min()
    }

    private static func isCandidate(_ reminder: Reminder, lastRuns: [String: AutoRun]) -> Bool {
        reminder.status == .open && reminder.autoRunMode != nil && !reminder.isWaiting
            && !hasRun(reminder, lastRun: lastRuns[reminder.id])
    }
}
