import Foundation

/// A link Tickler knows how to ask about. Every part is checked against a strict pattern: they end up as CLI arguments.
public enum LiveTarget: Hashable, Sendable {
    case gitlabMR(host: String, project: String, iid: Int)
    case jira(key: String)
    case githubPR(owner: String, repo: String, number: Int)

    public init?(link: ReminderLink) {
        guard let url = URL(string: link.url), let host = url.host(), host.wholeMatch(of: /[a-z0-9.-]+/) != nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let segment = /[A-Za-z0-9._-]+/
        switch link.kind {
        case .gitlabMR:
            guard let dash = parts.firstIndex(of: "-"), dash > 0, dash + 2 < parts.count, parts[dash + 1] == "merge_requests",
                  let iid = Int(parts[dash + 2]), parts[..<dash].allSatisfy({ $0.wholeMatch(of: segment) != nil }) else { return nil }
            self = .gitlabMR(host: host, project: parts[..<dash].joined(separator: "/"), iid: iid)
        case .jira:
            guard let index = parts.firstIndex(of: "browse"), index + 1 < parts.count,
                  parts[index + 1].wholeMatch(of: /[A-Z][A-Z0-9_]*-[0-9]+/) != nil else { return nil }
            self = .jira(key: parts[index + 1])
        case .githubPR:
            guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]),
                  parts[0].wholeMatch(of: segment) != nil, parts[1].wholeMatch(of: segment) != nil else { return nil }
            self = .githubPR(owner: parts[0], repo: parts[1], number: number)
        case .grafana, .slack, .other:
            return nil
        }
    }
}

public enum PipelineState: String, Codable, Sendable {
    case success
    case failed
    case running
    case pending
    case canceled
    case skipped
    case manual
    case created
    case other

    init(raw: String) {
        self = PipelineState(rawValue: raw) ??
            (raw == "waiting_for_resource" || raw == "preparing" || raw == "scheduled" ? .pending : .other)
    }
}

public struct MergeRequestStatus: Codable, Hashable, Sendable {
    public var iid: Int
    public var title: String
    public var state: String
    public var draft: Bool
    public var pipeline: PipelineState?
    public var pipelineURL: String?
    public var approvalsRequired: Int
    public var approvalsGiven: Int
    public var approvedBy: [String]
    public var userHasApproved: Bool
    public var userCanApprove: Bool
    public var mergeStatus: String
    public var hasConflicts: Bool
    public var discussionsResolved: Bool
    public var webURL: String
    public var author: String?
    public var userCanMerge: Bool = false

    /// GitLab has the last word: it says who may approve. Tickler only adds "still open and not approved by you yet".
    public var canApproveNow: Bool {
        state == "opened" && userCanApprove && !userHasApproved
    }

    /// GitLab's own verdict: approvals, pipeline, threads and conflicts are all clear, and the owner may merge.
    public var canMergeNow: Bool {
        state == "opened" && !draft && userCanMerge && mergeStatus == "mergeable"
    }

    /// Only the pipeline is left: GitLab can merge on its own once it passes.
    public var canMergeWhenPipelinePasses: Bool {
        state == "opened" && !draft && userCanMerge && mergeStatus == "ci_still_running"
    }
}

public struct TicketStatus: Codable, Hashable, Sendable {
    public enum Category: String, Codable, Sendable {
        case toDo
        case inProgress
        case done
    }

    public var key: String
    public var summary: String
    public var status: String
    public var category: Category
    public var assignee: String?
}

public struct CheckSummary: Codable, Hashable, Sendable {
    public var passed: Int
    public var failed: Int
    public var pending: Int
}

public struct PullRequestStatus: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var state: String
    public var draft: Bool
    public var reviewDecision: String?
    public var checks: CheckSummary
    public var url: String
}

public enum LiveStatus: Hashable, Sendable {
    case mergeRequest(MergeRequestStatus)
    case ticket(TicketStatus)
    case pullRequest(PullRequestStatus)
}

public enum LiveError: Error, Equatable, CustomStringConvertible {
    case toolMissing(String)
    case failed(tool: String, message: String)
    case unreadable(String)
    case unsupported

    public var description: String {
        switch self {
        case let .toolMissing(tool): "\(tool) is not installed"
        case let .failed(tool, message): message.isEmpty ? "\(tool) failed" : "\(tool): \(message)"
        case let .unreadable(what): "unexpected answer for \(what)"
        case .unsupported: "only GitLab merge requests can be approved or merged"
        }
    }
}
