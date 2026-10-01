import Foundation

/// Decodes the JSON printed by `glab api`, `jira issue view --raw` and `gh pr view --json`.
public enum LiveStatusParser {
    public static func mergeRequest(mr: Data, approvals: Data) throws -> MergeRequestStatus {
        struct MR: Decodable {
            struct User: Decodable { let username: String }
            struct Pipeline: Decodable {
                let status: String
                let webUrl: String?
            }

            let iid: Int
            let title: String
            let state: String
            let draft: Bool?
            let detailedMergeStatus: String?
            let hasConflicts: Bool?
            let blockingDiscussionsResolved: Bool?
            let webUrl: String
            struct Permissions: Decodable { let canMerge: Bool? }
            let author: User?
            let headPipeline: Pipeline?
            let user: Permissions?
        }
        struct Approvals: Decodable {
            struct Approver: Decodable {
                struct User: Decodable { let username: String }
                let user: User
            }

            let approvalsRequired: Int?
            let approvalsLeft: Int?
            let userHasApproved: Bool?
            let userCanApprove: Bool?
            let approvedBy: [Approver]?
        }
        let request = try decode(MR.self, from: mr, what: "merge request", snakeCase: true)
        let approval = try decode(Approvals.self, from: approvals, what: "merge request approvals", snakeCase: true)
        let approvedBy = (approval.approvedBy ?? []).map(\.user.username)
        return MergeRequestStatus(
            iid: request.iid,
            title: request.title,
            state: request.state,
            draft: request.draft ?? false,
            pipeline: request.headPipeline.map { PipelineState(raw: $0.status) },
            pipelineURL: request.headPipeline?.webUrl,
            approvalsRequired: approval.approvalsRequired ?? 0,
            approvalsGiven: approvedBy.count,
            approvedBy: approvedBy,
            userHasApproved: approval.userHasApproved ?? false,
            userCanApprove: approval.userCanApprove ?? false,
            mergeStatus: request.detailedMergeStatus ?? "unknown",
            hasConflicts: request.hasConflicts ?? false,
            discussionsResolved: request.blockingDiscussionsResolved ?? true,
            webURL: request.webUrl,
            author: request.author?.username,
            userCanMerge: request.user?.canMerge ?? false
        )
    }

    public static func ticket(_ data: Data) throws -> TicketStatus {
        struct Issue: Decodable {
            struct Fields: Decodable {
                struct Status: Decodable {
                    struct Category: Decodable { let key: String }
                    let name: String
                    let statusCategory: Category?
                }

                struct Person: Decodable { let displayName: String }
                let summary: String
                let status: Status
                let assignee: Person?
            }

            let key: String
            let fields: Fields
        }
        let issue = try decode(Issue.self, from: data, what: "Jira issue")
        let category: TicketStatus.Category = switch issue.fields.status.statusCategory?.key {
        case "done": .done
        case "indeterminate": .inProgress
        default: .toDo
        }
        return TicketStatus(
            key: issue.key, summary: issue.fields.summary, status: issue.fields.status.name,
            category: category, assignee: issue.fields.assignee?.displayName
        )
    }

    public static func pullRequest(_ data: Data) throws -> PullRequestStatus {
        struct PR: Decodable {
            struct Check: Decodable {
                let status: String?
                let conclusion: String?
                let state: String?
            }

            let number: Int
            let title: String
            let state: String
            let isDraft: Bool?
            let reviewDecision: String?
            let url: String
            let statusCheckRollup: [Check]?
        }
        let pr = try decode(PR.self, from: data, what: "pull request")
        var checks = CheckSummary(passed: 0, failed: 0, pending: 0)
        for check in pr.statusCheckRollup ?? [] {
            // CheckRun has status + conclusion, StatusContext only a state.
            let outcome = check.conclusion.flatMap { $0.isEmpty ? nil : $0 } ?? check.state ?? ""
            if check.status != nil, check.status != "COMPLETED" {
                checks.pending += 1
            } else if ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(outcome) {
                checks.passed += 1
            } else if ["PENDING", "EXPECTED", ""].contains(outcome) {
                checks.pending += 1
            } else {
                checks.failed += 1
            }
        }
        return PullRequestStatus(
            number: pr.number, title: pr.title, state: pr.state, draft: pr.isDraft ?? false,
            reviewDecision: pr.reviewDecision.flatMap { $0.isEmpty ? nil : $0 }, checks: checks, url: pr.url
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String, snakeCase: Bool = false) throws -> T {
        let decoder = JSONDecoder()
        if snakeCase {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LiveError.unreadable(what)
        }
    }
}
