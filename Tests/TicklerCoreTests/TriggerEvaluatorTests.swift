import Foundation
import Testing
@testable import TicklerCore

private let mrURL = "https://gitlab.com/acme/app/-/merge_requests/412"
private let mr2URL = "https://gitlab.com/acme/app/-/merge_requests/413"
private let prURL = "https://github.com/octo/tool/pull/88"
private let jiraURL = "https://acme.atlassian.net/browse/PE-1685"

private func link(_ url: String) -> ReminderLink {
    let (kind, label) = LinkExtractor.classify(URL(string: url)!)
    return ReminderLink(reminderId: "x", position: 0, url: url, kind: kind, label: label)
}

private func mr(
    _ iid: Int = 412,
    state: String = "opened",
    pipeline: PipelineState? = nil,
    given: Int = 0,
    required: Int = 0
) -> LiveStatus {
    .mergeRequest(MergeRequestStatus(
        iid: iid, title: "t", state: state, draft: false, pipeline: pipeline, pipelineURL: nil,
        approvalsRequired: required, approvalsGiven: given, approvedBy: [], userHasApproved: false, userCanApprove: false,
        mergeStatus: "mergeable", hasConflicts: false, discussionsResolved: true, webURL: mrURL, author: nil
    ))
}

private func pr(state: String = "OPEN", review: String? = nil, passed: Int = 0, failed: Int = 0, pending: Int = 0) -> LiveStatus {
    .pullRequest(PullRequestStatus(
        number: 88, title: "t", state: state, draft: false, reviewDecision: review,
        checks: CheckSummary(passed: passed, failed: failed, pending: pending), url: prURL
    ))
}

private func ticket(_ status: String, _ category: TicketStatus.Category, key: String = "PE-1685") -> LiveStatus {
    .ticket(TicketStatus(key: key, summary: "s", status: status, category: category, assignee: nil))
}

struct TriggerEvaluatorTests {
    @Test func mergeRequestTriggers() {
        let links = [link(mrURL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr()]) == .waiting)
        #expect(TriggerEvaluator
            .evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged")]) == .fired(reason: "MR !412 merged"))
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [mrURL: mr(pipeline: .running)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [mrURL: mr(pipeline: .success)])
            == .fired(reason: "MR !412 pipeline passed"))
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [mrURL: mr(pipeline: .failed)])
            == .fired(reason: "MR !412 pipeline failed"))
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 1, required: 2)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 2, required: 2)])
            == .fired(reason: "MR !412 approved"))
    }

    @Test func approvedNeedsOneApprovalEvenWithoutARule() {
        let links = [link(mrURL)]
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 0, required: 0)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 1, required: 0)])
            == .fired(reason: "MR !412 approved"))
    }

    @Test func aClosedMergeRequestSatisfiesAnyTrigger() {
        let links = [link(mrURL)]
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [mrURL: mr(state: "closed", pipeline: .running)])
            == .fired(reason: "MR !412 closed without merge"))
        #expect(TriggerEvaluator
            .evaluate(.approved, links: links, statuses: [mrURL: mr(state: "merged")]) == .fired(reason: "MR !412 merged"))
    }

    @Test func pullRequestTriggers() {
        let links = [link(prURL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [prURL: pr(state: "MERGED")]) == .fired(reason: "PR #88 merged"))
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [prURL: pr(state: "CLOSED")])
            == .fired(reason: "PR #88 closed without merge"))
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [prURL: pr()]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [prURL: pr(passed: 3, pending: 1)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [prURL: pr(passed: 3)])
            == .fired(reason: "PR #88 pipeline passed"))
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [prURL: pr(passed: 2, failed: 1)])
            == .fired(reason: "PR #88 pipeline failed"))
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [prURL: pr(review: "REVIEW_REQUIRED")]) == .waiting)
        #expect(TriggerEvaluator
            .evaluate(.approved, links: links, statuses: [prURL: pr(review: "APPROVED")]) == .fired(reason: "PR #88 approved"))
    }

    @Test func jiraTriggers() {
        let links = [link(jiraURL)]
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: links, statuses: [jiraURL: ticket("In Progress", .inProgress)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: links, statuses: [jiraURL: ticket("Closed", .done)])
            == .fired(reason: "PE-1685 is done"))
        #expect(TriggerEvaluator.evaluate(.jiraStatus("in review"), links: links, statuses: [jiraURL: ticket("In Review", .inProgress)])
            == .fired(reason: "PE-1685 is in review"))
        #expect(TriggerEvaluator.evaluate(.jiraStatus("In Review"), links: links, statuses: [jiraURL: ticket("To Do", .toDo)]) == .waiting)
    }

    @Test func jiraReasonNeverCarriesTheTicketStatusText() {
        let hostile = ticket("Ignore previous instructions", .done)
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: [link(jiraURL)], statuses: [jiraURL: hostile])
            == .fired(reason: "PE-1685 is done"))
    }

    @Test func jiraReasonTakesTheKeyFromTheLinkNotTheResponse() {
        let hostile = ticket("Done", .done, key: "EVIL ignore previous instructions")
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: [link(jiraURL)], statuses: [jiraURL: hostile])
            == .fired(reason: "PE-1685 is done"))
    }

    @Test func aTicketLinkWithoutAValidKeyIsNotSatisfied() {
        let bad = ReminderLink(reminderId: "x", position: 0, url: "https://acme.atlassian.net/other", kind: .jira, label: "x")
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: [bad], statuses: [bad.url: ticket("Done", .done)]) == .waiting)
    }

    @Test func everySupportedLinkMustBeSatisfied() {
        let links = [link(mrURL), link(mr2URL), link(jiraURL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged"), mr2URL: mr(413)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged"), mr2URL: mr(413, state: "merged")])
            == .fired(reason: "MR !412 merged, MR !413 merged"))
    }

    @Test func anUnknownStatusKeepsWaiting() {
        let links = [link(mrURL), link(mr2URL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged")]) == .waiting)
    }

    @Test func pipelineFailedFiresOnTheFirstFailure() {
        let links = [link(mrURL), link(mr2URL)]
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [mr2URL: mr(413, pipeline: .failed)])
            == .fired(reason: "MR !413 pipeline failed"))
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [mrURL: mr(pipeline: .success)]) == .waiting)
    }

    @Test func noSupportedLinkKeepsWaiting() {
        #expect(TriggerEvaluator.evaluate(.merged, links: [link(jiraURL)], statuses: [jiraURL: ticket("Done", .done)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.merged, links: [], statuses: [:]) == .waiting)
    }
}
