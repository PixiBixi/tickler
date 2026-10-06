import Foundation

public enum TriggerOutcome: Equatable, Sendable {
    case waiting
    case fired(reason: String)
}

/// Pure: whether the live state of a reminder's links satisfies its trigger. `statuses` is keyed by link URL; missing means unknown.
public enum TriggerEvaluator {
    public static func evaluate(_ trigger: Trigger, links: [ReminderLink], statuses: [String: LiveStatus]) -> TriggerOutcome {
        let reasons = links.filter { trigger.supports($0.kind) }
            .map { link in statuses[link.url].flatMap { reason(trigger, $0, link: link) } }
        guard !reasons.isEmpty else { return .waiting }
        // A failure anywhere is news; every other trigger waits for all of its links.
        if trigger == .pipelineFailed {
            let failures = reasons.compactMap(\.self)
            return failures.isEmpty ? .waiting : .fired(reason: failures.joined(separator: ", "))
        }
        guard reasons.allSatisfy({ $0 != nil }) else { return .waiting }
        return .fired(reason: reasons.compactMap(\.self).joined(separator: ", "))
    }

    /// Why this status satisfies the trigger, nil when it does not.
    static func reason(_ trigger: Trigger, _ status: LiveStatus, link: ReminderLink) -> String? {
        switch status {
        case let .mergeRequest(mr): mergeRequestReason(trigger, mr)
        case let .pullRequest(pr): pullRequestReason(trigger, pr)
        case let .ticket(ticket): ticketReason(trigger, ticket, link: link)
        }
    }

    private static func mergeRequestReason(_ trigger: Trigger, _ mr: MergeRequestStatus) -> String? {
        let name = "MR !\(mr.iid)"
        if mr.state == "merged" {
            return "\(name) merged"
        }
        // Closed: the awaited event can no longer happen, so say it now rather than at the deadline.
        if mr.state != "opened" {
            return "\(name) closed without merge"
        }
        switch trigger {
        case .pipelineGreen: return mr.pipeline == .success ? "\(name) pipeline passed" : nil
        case .pipelineFailed: return mr.pipeline == .failed ? "\(name) pipeline failed" : nil
        case .approved: return mr.approvalsGiven >= max(mr.approvalsRequired, 1) ? "\(name) approved" : nil
        case .merged, .jiraDone, .jiraStatus: return nil
        }
    }

    private static func pullRequestReason(_ trigger: Trigger, _ pr: PullRequestStatus) -> String? {
        let name = "PR #\(pr.number)"
        if pr.state == "MERGED" {
            return "\(name) merged"
        }
        if pr.state != "OPEN" {
            return "\(name) closed without merge"
        }
        switch trigger {
        case .pipelineGreen:
            return pr.checks.passed > 0 && pr.checks.failed == 0 && pr.checks.pending == 0 ? "\(name) pipeline passed" : nil
        case .pipelineFailed: return pr.checks.failed > 0 ? "\(name) pipeline failed" : nil
        case .approved: return pr.reviewDecision == "APPROVED" ? "\(name) approved" : nil
        case .merged, .jiraDone, .jiraStatus: return nil
        }
    }

    private static func ticketReason(_ trigger: Trigger, _ ticket: TicketStatus, link: ReminderLink) -> String? {
        // The reason is the resume message sent to Claude: the key comes from the validated link, never from the response.
        guard case let .jira(key)? = LiveTarget(link: link) else { return nil }
        switch trigger {
        case .jiraDone: return ticket.category == .done ? "\(key) is done" : nil
        case let .jiraStatus(name):
            return ticket.status.caseInsensitiveCompare(name) == .orderedSame ? "\(key) is \(name)" : nil
        case .merged, .pipelineGreen, .pipelineFailed, .approved: return nil
        }
    }
}
