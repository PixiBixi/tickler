import Foundation
import Testing
@testable import TicklerCore

private func link(_ url: String) -> ReminderLink {
    let (kind, label) = LinkExtractor.classify(URL(string: url)!)
    return ReminderLink(reminderId: "x", position: 0, url: url, kind: kind, label: label)
}

struct LiveTargetTests {
    @Test func recognizesTargets() {
        #expect(LiveTarget(link: link("https://gitlab.com/acme/infra/monitoring/prober/-/merge_requests/221"))
            == .gitlabMR(host: "gitlab.com", project: "acme/infra/monitoring/prober", iid: 221))
        #expect(LiveTarget(link: link("https://git.example.org/team/app/-/merge_requests/7/diffs"))
            == .gitlabMR(host: "git.example.org", project: "team/app", iid: 7))
        #expect(LiveTarget(link: link("https://acme.atlassian.net/browse/OPS-42")) == .jira(key: "OPS-42"))
        #expect(LiveTarget(link: link("https://github.com/octo/tool/pull/12")) == .githubPR(owner: "octo", repo: "tool", number: 12))
        #expect(LiveTarget(link: link("https://grafana.example.org/d/abc")) == nil)
    }

    @Test func rejectsUnexpectedCharacters() {
        #expect(LiveTarget(link: link("https://gitlab.com/a/b%20c/-/merge_requests/1")) == nil)
        #expect(LiveTarget(link: ReminderLink(
            reminderId: "x",
            position: 0,
            url: "https://acme.atlassian.net/browse/OPS-1;rm",
            kind: .jira,
            label: "x"
        )) == nil)
    }
}

struct LiveStatusParserTests {
    @Test func parsesAMergeRequest() throws {
        let mr = #"""
        {"iid":221,"title":"refactor(tools): share tools","state":"opened","draft":false,
         "detailed_merge_status":"not_approved","has_conflicts":false,"blocking_discussions_resolved":true,
         "web_url":"https://gitlab.com/acme/prober/-/merge_requests/221","author":{"username":"alice"},
         "head_pipeline":{"status":"success","web_url":"https://gitlab.com/acme/prober/-/pipelines/9"}}
        """#
        let approvals = #"""
        {"approvals_required":1,"approvals_left":1,"user_has_approved":false,"user_can_approve":true,"approved":false,
         "approved_by":[]}
        """#
        let status = try LiveStatusParser.mergeRequest(mr: Data(mr.utf8), approvals: Data(approvals.utf8))
        #expect(status.iid == 221)
        #expect(status.state == "opened")
        #expect(status.pipeline == .success)
        #expect(status.approvalsGiven == 0)
        #expect(status.approvalsRequired == 1)
        #expect(status.canApproveNow)
        #expect(status.author == "alice")
    }

    @Test func mergedOrApprovedCannotBeApproved() throws {
        let mr = #"{"iid":3,"title":"t","state":"merged","draft":false,"detailed_merge_status":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"web_url":"u","author":{"username":"bob"},"head_pipeline":null}"#
        let approvals = #"{"approvals_required":2,"approvals_left":0,"user_has_approved":true,"user_can_approve":true,"approved_by":[{"user":{"username":"alice"}},{"user":{"username":"carol"}}]}"#
        let status = try LiveStatusParser.mergeRequest(mr: Data(mr.utf8), approvals: Data(approvals.utf8))
        #expect(status.pipeline == nil)
        #expect(status.approvalsGiven == 2)
        #expect(status.approvedBy == ["alice", "carol"])
        #expect(!status.canApproveNow)
    }

    @Test func parsesATicket() throws {
        let raw = #"{"key":"OPS-42","fields":{"summary":"Rotate the keys","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"assignee":{"displayName":"Alice"}}}"#
        let ticket = try LiveStatusParser.ticket(Data(raw.utf8))
        #expect(ticket == TicketStatus(
            key: "OPS-42",
            summary: "Rotate the keys",
            status: "In Progress",
            category: .inProgress,
            assignee: "Alice"
        ))
        let unassigned = #"{"key":"OPS-1","fields":{"summary":"s","status":{"name":"Done","statusCategory":{"key":"done"}},"assignee":null}}"#
        #expect(try LiveStatusParser.ticket(Data(unassigned.utf8)).assignee == nil)
    }

    @Test func parsesAPullRequestAndSummarizesChecks() throws {
        let raw = #"""
        {"number":12,"title":"chore(deps): bump","state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED",
         "url":"https://github.com/octo/tool/pull/12","statusCheckRollup":[
          {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},
          {"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":""},
          {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]}
        """#
        let pr = try LiveStatusParser.pullRequest(Data(raw.utf8))
        #expect(pr.checks == CheckSummary(passed: 2, failed: 1, pending: 1))
        #expect(pr.reviewDecision == "REVIEW_REQUIRED")
        #expect(pr.state == "OPEN")
    }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] {
        lock.withLock { recorded }
    }

    var responses: [String: String] = [:]
    var failure: LiveError?

    func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        lock.withLock { recorded.append([tool] + arguments) }
        if let failure {
            throw failure
        }
        let key = ([tool] + arguments).joined(separator: " ")
        guard let match = responses.first(where: { key.hasSuffix($0.key) }) else { return Data("{}".utf8) }
        return Data(match.value.utf8)
    }
}

struct LiveStatusFetcherTests {
    @Test func gitLabCallsUseTheHostAndTheEncodedProject() async throws {
        let runner = FakeRunner()
        runner.responses = [
            "merge_requests/5": #"{"iid":5,"title":"t","state":"opened","draft":true,"detailed_merge_status":"draft_status","has_conflicts":true,"blocking_discussions_resolved":false,"web_url":"u","author":{"username":"a"},"head_pipeline":{"status":"failed","web_url":"p"}}"#,
            "merge_requests/5/approvals": #"{"approvals_required":1,"approvals_left":1,"user_has_approved":false,"user_can_approve":false,"approved_by":[]}"#,
        ]
        let fetcher = LiveStatusFetcher(runner: runner)
        let status = try await fetcher.fetch(.gitlabMR(host: "gitlab.com", project: "acme/infra/app", iid: 5))
        #expect(Set(runner.calls) == [
            ["glab", "api", "--hostname", "gitlab.com", "projects/acme%2Finfra%2Fapp/merge_requests/5"],
            ["glab", "api", "--hostname", "gitlab.com", "projects/acme%2Finfra%2Fapp/merge_requests/5/approvals"],
        ])
        guard case let .mergeRequest(mr) = status else { Issue.record("not an MR"); return }
        #expect(mr.draft && mr.hasConflicts && !mr.discussionsResolved && mr.pipeline == .failed)
    }

    @Test func approvePostsToTheApproveEndpoint() async throws {
        let runner = FakeRunner()
        try await LiveStatusFetcher(runner: runner).approve(.gitlabMR(host: "gitlab.com", project: "acme/app", iid: 9))
        #expect(runner.calls == [["glab", "api", "--hostname", "gitlab.com", "-X", "POST", "projects/acme%2Fapp/merge_requests/9/approve"]])
    }

    @Test func jiraAndGitHubCalls() async throws {
        let runner = FakeRunner()
        runner.responses = [
            "--raw": #"{"key":"OPS-1","fields":{"summary":"s","status":{"name":"To Do","statusCategory":{"key":"new"}},"assignee":null}}"#,
            "statusCheckRollup,url": #"{"number":1,"title":"t","state":"MERGED","isDraft":false,"reviewDecision":"APPROVED","url":"u","statusCheckRollup":[]}"#,
        ]
        let fetcher = LiveStatusFetcher(runner: runner)
        _ = try await fetcher.fetch(.jira(key: "OPS-1"))
        _ = try await fetcher.fetch(.githubPR(owner: "octo", repo: "tool", number: 1))
        #expect(runner.calls == [
            ["jira", "issue", "view", "OPS-1", "--raw"],
            [
                "gh",
                "pr",
                "view",
                "https://github.com/octo/tool/pull/1",
                "--json",
                "number,title,state,isDraft,reviewDecision,statusCheckRollup,url",
            ],
        ])
    }

    @Test func mergePutsToTheMergeEndpoint() async throws {
        let runner = FakeRunner()
        let fetcher = LiveStatusFetcher(runner: runner)
        try await fetcher.merge(.gitlabMR(host: "gitlab.com", project: "acme/app", iid: 9))
        try await fetcher.merge(.gitlabMR(host: "gitlab.com", project: "acme/app", iid: 9), whenPipelinePasses: true)
        #expect(runner.calls == [
            ["glab", "api", "--hostname", "gitlab.com", "-X", "PUT", "projects/acme%2Fapp/merge_requests/9/merge"],
            ["glab", "api", "--hostname", "gitlab.com", "-X", "PUT", "projects/acme%2Fapp/merge_requests/9/merge", "-f", "auto_merge=true"],
        ])
    }

    @Test func mergeAvailabilityFollowsGitLab() throws {
        func status(_ mergeStatus: String, canMerge: Bool, draft: Bool = false) throws -> MergeRequestStatus {
            let mr = #"{"iid":1,"title":"t","state":"opened","draft":\#(draft),"detailed_merge_status":"\#(mergeStatus)","web_url":"u","user":{"can_merge":\#(canMerge)}}"#
            return try LiveStatusParser.mergeRequest(mr: Data(mr.utf8), approvals: Data("{}".utf8))
        }
        #expect(try status("mergeable", canMerge: true).canMergeNow)
        #expect(try !status("mergeable", canMerge: false).canMergeNow)
        #expect(try !status("not_approved", canMerge: true).canMergeNow)
        #expect(try !status("mergeable", canMerge: true, draft: true).canMergeNow)
        #expect(try status("ci_still_running", canMerge: true).canMergeWhenPipelinePasses)
    }

    @Test func approvingAnythingButAnMRIsRefused() async {
        await #expect(throws: LiveError.unsupported) {
            try await LiveStatusFetcher(runner: FakeRunner()).approve(.jira(key: "OPS-1"))
        }
    }

    @Test func loginShellCommandPassesArgumentsAsParameters() {
        let command = LoginShellRunner.command(shell: "/bin/zsh", tool: "jira", arguments: ["issue", "view", "OPS-1; rm -rf ~"])
        #expect(command == ["/bin/zsh", "-lic", #"exec "$0" "$@""#, "jira", "issue", "view", "OPS-1; rm -rf ~"])
    }

    @Test func appRunnerHandsTheToolItsExtraEnvironment() async throws {
        let runner = AppToolRunner { tool in tool == "env" ? ["TICKLER_PROBE": "token-value"] : [:] }
        let output = try await String(decoding: runner.run("env", []), as: UTF8.self)
        #expect(output.contains("TICKLER_PROBE=token-value"))
    }

    @Test func failureMessageDropsColorCodesAndTrailingResets() {
        let stderr = "\u{1B}[31m\u{1B}[1mError:\u{1B}[0m 401 Unauthorized\n\u{1B}[0m\n"
        #expect(LiveError.failureMessage(Data(stderr.utf8)) == "Error: 401 Unauthorized")
        #expect(LiveError.failureMessage(Data("\u{1B}[0m".utf8)) == "")
    }
}

struct LiveStatusFinishedTests {
    @Test func finishedFollowsEachKind() throws {
        let merged = #"{"iid":1,"title":"t","state":"merged","web_url":"u"}"#
        let open = #"{"iid":2,"title":"t","state":"opened","web_url":"u"}"#
        #expect(try LiveStatus.mergeRequest(LiveStatusParser.mergeRequest(mr: Data(merged.utf8), approvals: Data("{}".utf8))).isFinished)
        #expect(try !LiveStatus.mergeRequest(LiveStatusParser.mergeRequest(mr: Data(open.utf8), approvals: Data("{}".utf8))).isFinished)
        let done = #"{"key":"OPS-1","fields":{"summary":"s","status":{"name":"Done","statusCategory":{"key":"done"}}}}"#
        #expect(try LiveStatus.ticket(LiveStatusParser.ticket(Data(done.utf8))).isFinished)
    }
}
