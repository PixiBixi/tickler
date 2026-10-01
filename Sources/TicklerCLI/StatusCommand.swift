import ArgumentParser
import Foundation
import TicklerCore

/// One linked item and what glab, jira or gh said about it.
struct LinkStatusJSON: Encodable {
    let kind: String
    let label: String
    let url: String
    var mergeRequest: MergeRequestStatus?
    var ticket: TicketStatus?
    var pullRequest: PullRequestStatus?
    var error: String?
}

struct StatusCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Live status of the MRs, tickets and PRs linked to a reminder (glab, jira, gh)."
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Reminder id.") var id: String
    @Flag(help: "Print a JSON array, one entry per supported link.") var json = false

    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        _ = try context.loadReminder(id, from: store)
        let links = try store.links(for: id).filter { LiveTarget(link: $0) != nil }
        let fetcher = LiveStatusFetcher(runner: context.liveRunner)
        let results = waitFor {
            await withTaskGroup(of: (Int, LinkStatusJSON).self) { group in
                for (index, link) in links.enumerated() {
                    group.addTask { await (index, Self.status(of: link, fetcher: fetcher)) }
                }
                var collected: [(Int, LinkStatusJSON)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        if json {
            try context.stdout.line(context.encodeJSON(results))
        } else if results.isEmpty {
            context.stdout.line("no MR, ticket or PR linked to \(id)")
        } else {
            results.forEach { context.stdout.line(Self.line($0)) }
        }
    }

    static func status(of link: ReminderLink, fetcher: LiveStatusFetcher) async -> LinkStatusJSON {
        var entry = LinkStatusJSON(kind: link.kind.rawValue, label: link.label, url: link.url)
        guard let target = LiveTarget(link: link) else { return entry }
        do {
            switch try await fetcher.fetch(target) {
            case let .mergeRequest(status): entry.mergeRequest = status
            case let .ticket(status): entry.ticket = status
            case let .pullRequest(status): entry.pullRequest = status
            }
        } catch {
            entry.error = String(describing: error)
        }
        return entry
    }

    static func line(_ entry: LinkStatusJSON) -> String {
        let head = "\(entry.label)"
        if let error = entry.error {
            return "\(head)  error: \(error)"
        }
        if let mr = entry.mergeRequest {
            var parts = [mr.draft ? "draft" : mr.state]
            parts.append("pipeline \(mr.pipeline?.rawValue ?? "none")")
            parts.append("approvals \(mr.approvalsGiven)/\(mr.approvalsRequired)")
            if mr.hasConflicts {
                parts.append("conflicts")
            }
            if !mr.discussionsResolved {
                parts.append("unresolved threads")
            }
            if mr.canApproveNow {
                parts.append("you can approve")
            }
            if mr.canMergeNow {
                parts.append("you can merge")
            }
            parts.append(mr.mergeStatus)
            return "\(head)  " + parts.joined(separator: ", ")
        }
        if let ticket = entry.ticket {
            return "\(head)  \(ticket.status), \(ticket.assignee ?? "unassigned"), \(ticket.summary)"
        }
        if let pr = entry.pullRequest {
            let checks = "checks \(pr.checks.passed) passed, \(pr.checks.failed) failed, \(pr.checks.pending) pending"
            return "\(head)  " + ([pr.draft ? "DRAFT" : pr.state, checks] + [pr.reviewDecision].compactMap(\.self)).joined(separator: ", ")
        }
        return head
    }
}

/// ArgumentParser commands are synchronous here; the CLI waits for the concurrent lookups on a semaphore.
func waitFor<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
