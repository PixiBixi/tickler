# Event Triggers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reminder can wait for an event on its links (MR merged, pipeline green or failed, approved, Jira status); when it happens, the reminder becomes due now and notifies like any other.

**Architecture:** Pure core units (`Trigger`, `TriggerEvaluator`) plus three nullable columns and an idempotent `ReminderStore.fire`. The CLI sets and shows triggers. Tickler.app runs a 5 minute `TriggerWatcher` that fetches live statuses through the existing `LiveStatusStore`, evaluates, fires, then lets the existing catch-up notify.

**Tech Stack:** Swift 6, SwiftPM (TicklerCore, TicklerCLI), swift-argument-parser, GRDB, Swift Testing, SwiftUI app built with XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-06-tickler-event-triggers-design.md`

## Global Constraints

- Triggers, exact strings: `merged`, `pipeline-green`, `pipeline-failed`, `approved`, `jira:done`, `jira:<status name>`.
- One trigger per reminder; the due date stays mandatory and is the fallback deadline.
- Default deadline with `--when` and no `--at`: 3 working days later (Monday to Friday) at 09:30.
- A trigger never marks a reminder done. Firing does not bump `rescheduleCount` nor change `originalDueAt`.
- Watcher interval: 5 minutes (300 s). Evaluation only in Tickler.app; the CLI never polls.
- Trigger with no supported link: refused by `add` and `edit` with exit code 2.
- CLI output is English. App strings are English with French translations in `App/Resources/Localizable.xcstrings`.
- `skills/tickler/SKILL.md` is embedded by `scripts/embed-skill.sh` into `Sources/TicklerCore/Skill/SkillContent.swift`: never edit the generated file by hand.
- Commits: Conventional Commits, one scope per commit, signed (`git log --format="%h %G?"` shows `G`). Never push.
- No em dash, en dash or bullet character in code comments, docs or strings.
- Code comments 1 to 3 lines, matching the surrounding style (`///` doc comments on public API).

## Review Focus

1. Two watcher ticks, or the watcher and a CLI edit, firing the same reminder: the second `fire` must be a no-op (pinned in Task 3).
2. Claude reschedules a waiting reminder with `tickler edit --at`: it must stay waiting (pinned in Task 4).
3. An MR closed without merge under `pipeline-green`: fires with "closed without merge" instead of waiting until the deadline (pinned in Task 2).
4. One of two linked MRs fails to fetch: stays waiting, never fires on partial data (pinned in Task 2).
5. A reminder marked done or deleted while waiting: the watcher must never fire it (pinned in Task 3).

---

### Task 1: `Trigger` type and default deadline

**Files:**
- Create: `Sources/TicklerCore/Triggers/Trigger.swift`
- Test: `Tests/TicklerCoreTests/TriggerTests.swift`

**Interfaces:**
- Consumes: `LinkKind` (`Sources/TicklerCore/Links/LinkExtractor.swift:3`).
- Produces: `public enum Trigger: Hashable, Sendable` with cases `merged, pipelineGreen, pipelineFailed, approved, jiraDone, jiraStatus(String)`; `init?(_ raw: String)`; `var rawValue: String`; `func supports(_ kind: LinkKind) -> Bool`; `static let usage: String`; `static func defaultDeadline(after now: Date, calendar: Calendar) -> Date`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TicklerCore

struct TriggerTests {
    @Test func parsesEveryForm() {
        #expect(Trigger("merged") == .merged)
        #expect(Trigger(" Pipeline-Green ") == .pipelineGreen)
        #expect(Trigger("pipeline-failed") == .pipelineFailed)
        #expect(Trigger("approved") == .approved)
        #expect(Trigger("jira:done") == .jiraDone)
        #expect(Trigger("JIRA:Done") == .jiraDone)
        #expect(Trigger("jira:In Review") == .jiraStatus("In Review"))
        #expect(Trigger("jira: In Review ") == .jiraStatus("In Review"))
    }

    @Test func rejectsUnknownForms() {
        #expect(Trigger("") == nil)
        #expect(Trigger("green") == nil)
        #expect(Trigger("jira:") == nil)
        #expect(Trigger("jira:  ") == nil)
        #expect(Trigger("jira:a\nb") == nil)
    }

    @Test func rawValueRoundTrips() {
        let all: [Trigger] = [.merged, .pipelineGreen, .pipelineFailed, .approved, .jiraDone, .jiraStatus("In Review")]
        for trigger in all {
            #expect(Trigger(trigger.rawValue) == trigger)
        }
        #expect(Trigger.jiraStatus("In Review").rawValue == "jira:In Review")
    }

    @Test func supportedLinkKinds() {
        #expect(Trigger.merged.supports(.gitlabMR))
        #expect(Trigger.approved.supports(.githubPR))
        #expect(!Trigger.pipelineGreen.supports(.jira))
        #expect(Trigger.jiraDone.supports(.jira))
        #expect(!Trigger.jiraStatus("x").supports(.gitlabMR))
        #expect(!Trigger.merged.supports(.slack))
    }

    @Test func defaultDeadlineSkipsWeekends() {
        // Fixture.now is Thursday 2026-10-01 10:45: Fri 2, Mon 5, Tue 6.
        #expect(Trigger.defaultDeadline(after: Fixture.now, calendar: Fixture.calendar) == Fixture.date("2026-10-06 09:30"))
        #expect(Trigger.defaultDeadline(after: Fixture.date("2026-10-02 18:00"), calendar: Fixture.calendar)
            == Fixture.date("2026-10-07 09:30"))
        #expect(Trigger.defaultDeadline(after: Fixture.date("2026-10-03 12:00"), calendar: Fixture.calendar)
            == Fixture.date("2026-10-08 09:30"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TriggerTests`
Expected: build failure, `cannot find 'Trigger' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// An event on a reminder's links that makes it due now. Stored as typed: `merged`, `jira:In Review`.
public enum Trigger: Hashable, Sendable {
    case merged
    case pipelineGreen
    case pipelineFailed
    case approved
    /// Status category Done, whatever the workflow calls it.
    case jiraDone
    /// Exact status name, compared case-insensitively.
    case jiraStatus(String)

    public static let usage = "merged, pipeline-green, pipeline-failed, approved, jira:done or jira:<status>"

    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.contains(where: \.isNewline) else { return nil }
        switch text.lowercased() {
        case "merged": self = .merged
        case "pipeline-green": self = .pipelineGreen
        case "pipeline-failed": self = .pipelineFailed
        case "approved": self = .approved
        default:
            guard text.lowercased().hasPrefix("jira:") else { return nil }
            let name = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = name.lowercased() == "done" ? .jiraDone : .jiraStatus(name)
        }
    }

    public var rawValue: String {
        switch self {
        case .merged: "merged"
        case .pipelineGreen: "pipeline-green"
        case .pipelineFailed: "pipeline-failed"
        case .approved: "approved"
        case .jiraDone: "jira:done"
        case let .jiraStatus(name): "jira:\(name)"
        }
    }

    public func supports(_ kind: LinkKind) -> Bool {
        switch self {
        case .merged, .pipelineGreen, .pipelineFailed, .approved: kind == .gitlabMR || kind == .githubPR
        case .jiraDone, .jiraStatus: kind == .jira
        }
    }

    /// The fallback deadline when none is given: 3 working days later, at 09:30.
    public static func defaultDeadline(after now: Date, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: now)
        var left = 3
        while left > 0 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if !calendar.isDateInWeekend(day) {
                left -= 1
            }
        }
        return calendar.date(bySettingHour: 9, minute: 30, second: 0, of: day)!
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TriggerTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/TicklerCore/Triggers/Trigger.swift Tests/TicklerCoreTests/TriggerTests.swift
git commit -m "feat(core): trigger type with a default deadline"
```

---

### Task 2: `TriggerEvaluator`

**Files:**
- Create: `Sources/TicklerCore/Triggers/TriggerEvaluator.swift`
- Test: `Tests/TicklerCoreTests/TriggerEvaluatorTests.swift`

**Interfaces:**
- Consumes: `Trigger` (Task 1); `LiveStatus`, `MergeRequestStatus`, `PullRequestStatus`, `TicketStatus`, `CheckSummary` (`Sources/TicklerCore/Live/LiveStatus.swift`); `ReminderLink(reminderId:position:url:kind:label:)`.
- Produces: `public enum TriggerOutcome: Equatable, Sendable { case waiting, fired(reason: String) }`; `public enum TriggerEvaluator { static func evaluate(_ trigger: Trigger, links: [ReminderLink], statuses: [String: LiveStatus]) -> TriggerOutcome }` where `statuses` is keyed by link URL and a missing key means unknown.

Rules (from the spec):
- Only links with `trigger.supports(link.kind)` count. None: `.waiting`.
- All counted links must be satisfied, except `pipelineFailed` which fires on the first satisfied one; unknown statuses are not satisfied (and ignored for `pipelineFailed`).
- MR `state == "merged"` or PR `state == "MERGED"`: satisfied with reason `"!412 merged"` / `"#88 merged"`, for any MR/PR trigger. Any other non-open state (`closed`, `locked`, `CLOSED`): satisfied with `"!412 closed without merge"`.
- Open MR: `pipelineGreen` if `pipeline == .success` (`"!412 pipeline passed"`), `pipelineFailed` if `pipeline == .failed` (`"!412 pipeline failed"`), `approved` if `approvalsGiven >= max(approvalsRequired, 1)` (`"!412 approved"`), `merged` never.
- Open PR: `pipelineGreen` if `checks.passed > 0 && checks.failed == 0 && checks.pending == 0`, `pipelineFailed` if `checks.failed > 0`, `approved` if `reviewDecision == "APPROVED"`.
- Ticket: `jiraDone` if `category == .done`, `jiraStatus(name)` if `status` equals `name` case-insensitively; reason `"PE-1685 is Done"` using the ticket's own status name.
- Several reasons are joined with `", "` in link order.

- [ ] **Step 1: Write the failing tests**

```swift
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

private func mr(_ iid: Int = 412, state: String = "opened", pipeline: PipelineState? = nil, given: Int = 0, required: Int = 0) -> LiveStatus {
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

private func ticket(_ status: String, _ category: TicketStatus.Category) -> LiveStatus {
    .ticket(TicketStatus(key: "PE-1685", summary: "s", status: status, category: category, assignee: nil))
}

struct TriggerEvaluatorTests {
    @Test func mergeRequestTriggers() {
        let links = [link(mrURL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr()]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged")]) == .fired(reason: "!412 merged"))
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [mrURL: mr(pipeline: .running)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [mrURL: mr(pipeline: .success)])
            == .fired(reason: "!412 pipeline passed"))
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [mrURL: mr(pipeline: .failed)])
            == .fired(reason: "!412 pipeline failed"))
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 1, required: 2)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 2, required: 2)])
            == .fired(reason: "!412 approved"))
    }

    @Test func approvedNeedsOneApprovalEvenWithoutARule() {
        let links = [link(mrURL)]
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 0, required: 0)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(given: 1, required: 0)])
            == .fired(reason: "!412 approved"))
    }

    @Test func aClosedMergeRequestSatisfiesAnyTrigger() {
        let links = [link(mrURL)]
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [mrURL: mr(state: "closed", pipeline: .running)])
            == .fired(reason: "!412 closed without merge"))
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [mrURL: mr(state: "merged")]) == .fired(reason: "!412 merged"))
    }

    @Test func pullRequestTriggers() {
        let links = [link(prURL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [prURL: pr(state: "MERGED")]) == .fired(reason: "#88 merged"))
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [prURL: pr(state: "CLOSED")])
            == .fired(reason: "#88 closed without merge"))
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [prURL: pr()]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [prURL: pr(passed: 3, pending: 1)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.pipelineGreen, links: links, statuses: [prURL: pr(passed: 3)])
            == .fired(reason: "#88 pipeline passed"))
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [prURL: pr(passed: 2, failed: 1)])
            == .fired(reason: "#88 pipeline failed"))
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [prURL: pr(review: "REVIEW_REQUIRED")]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.approved, links: links, statuses: [prURL: pr(review: "APPROVED")]) == .fired(reason: "#88 approved"))
    }

    @Test func jiraTriggers() {
        let links = [link(jiraURL)]
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: links, statuses: [jiraURL: ticket("In Progress", .inProgress)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.jiraDone, links: links, statuses: [jiraURL: ticket("Closed", .done)])
            == .fired(reason: "PE-1685 is Closed"))
        #expect(TriggerEvaluator.evaluate(.jiraStatus("in review"), links: links, statuses: [jiraURL: ticket("In Review", .inProgress)])
            == .fired(reason: "PE-1685 is In Review"))
        #expect(TriggerEvaluator.evaluate(.jiraStatus("In Review"), links: links, statuses: [jiraURL: ticket("To Do", .toDo)]) == .waiting)
    }

    @Test func everySupportedLinkMustBeSatisfied() {
        let links = [link(mrURL), link(mr2URL), link(jiraURL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged"), mr2URL: mr(413)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged"), mr2URL: mr(413, state: "merged")])
            == .fired(reason: "!412 merged, !413 merged"))
    }

    @Test func anUnknownStatusKeepsWaiting() {
        let links = [link(mrURL), link(mr2URL)]
        #expect(TriggerEvaluator.evaluate(.merged, links: links, statuses: [mrURL: mr(state: "merged")]) == .waiting)
    }

    @Test func pipelineFailedFiresOnTheFirstFailure() {
        let links = [link(mrURL), link(mr2URL)]
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [mr2URL: mr(413, pipeline: .failed)])
            == .fired(reason: "!413 pipeline failed"))
        #expect(TriggerEvaluator.evaluate(.pipelineFailed, links: links, statuses: [mrURL: mr(pipeline: .success)]) == .waiting)
    }

    @Test func noSupportedLinkKeepsWaiting() {
        #expect(TriggerEvaluator.evaluate(.merged, links: [link(jiraURL)], statuses: [jiraURL: ticket("Done", .done)]) == .waiting)
        #expect(TriggerEvaluator.evaluate(.merged, links: [], statuses: [:]) == .waiting)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TriggerEvaluatorTests`
Expected: build failure, `cannot find 'TriggerEvaluator' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum TriggerOutcome: Equatable, Sendable {
    case waiting
    case fired(reason: String)
}

/// Pure: whether the live state of a reminder's links satisfies its trigger. `statuses` is keyed by link URL; missing means unknown.
public enum TriggerEvaluator {
    public static func evaluate(_ trigger: Trigger, links: [ReminderLink], statuses: [String: LiveStatus]) -> TriggerOutcome {
        let reasons = links.filter { trigger.supports($0.kind) }.map { link in statuses[link.url].flatMap { reason(trigger, $0) } }
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
    static func reason(_ trigger: Trigger, _ status: LiveStatus) -> String? {
        switch status {
        case let .mergeRequest(mr):
            let name = "!\(mr.iid)"
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
        case let .pullRequest(pr):
            let name = "#\(pr.number)"
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
        case let .ticket(ticket):
            let reached = switch trigger {
            case .jiraDone: ticket.category == .done
            case let .jiraStatus(name): ticket.status.caseInsensitiveCompare(name) == .orderedSame
            case .merged, .pipelineGreen, .pipelineFailed, .approved: false
            }
            return reached ? "\(ticket.key) is \(ticket.status)" : nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TriggerEvaluatorTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/TicklerCore/Triggers/TriggerEvaluator.swift Tests/TicklerCoreTests/TriggerEvaluatorTests.swift
git commit -m "feat(core): evaluate a trigger against the live status of the links"
```

---

### Task 3: Storage: columns, model fields, `setTrigger`, `fire`, resume message, waiting bucket

**Files:**
- Modify: `Sources/TicklerCore/Store/TicklerDatabase.swift:63-68` (new migration after `v2-resume-prompt`)
- Modify: `Sources/TicklerCore/Model/Reminder.swift` (fields, computed properties, draft)
- Modify: `Sources/TicklerCore/Store/ReminderStore.swift` (`add`, new `setTrigger`, new `fire`)
- Modify: `Sources/TicklerCore/Dates/DueBucket.swift` (new `.waiting` case and `of(_ reminder:)`)
- Modify: `Sources/TicklerCLI/ReminderTable.swift` and `App/Sources/Model/Format.swift:46-54`, `App/Sources/Views/Theme.swift:18-24`: only the exhaustive switches the new case breaks
- Test: `Tests/TicklerCoreTests/TriggerStoreTests.swift`

**Interfaces:**
- Consumes: `Trigger` (Task 1).
- Produces:
  - `Reminder.trigger: String?`, `Reminder.firedAt: Date?`, `Reminder.firedReason: String?` (all default `nil`)
  - `Reminder.parsedTrigger: Trigger?`, `Reminder.isWaiting: Bool` (open and `trigger != nil`), `Reminder.resumeMessage: String?`
  - `ReminderDraft(..., trigger: Trigger? = nil)` (new last parameter)
  - `ReminderStore.setTrigger(_ id: String, _ trigger: Trigger?) throws -> Reminder` (`@discardableResult`)
  - `ReminderStore.fire(_ id: String, reason: String, at date: Date) throws -> Bool` (`@discardableResult`)
  - `DueBucket.waiting` (last in `allCases`), `DueBucket.of(_ reminder: Reminder, now: Date, calendar: Calendar = .current) -> DueBucket`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import GRDB
import Testing
@testable import TicklerCore

struct TriggerStoreTests {
    private func waiting(_ store: ReminderStore, trigger: Trigger = .merged, at due: String = "2026-10-06 09:30") throws -> Reminder {
        var draft = Fixture.draft("rebase", at: due, notes: "https://gitlab.com/acme/app/-/merge_requests/412")
        draft.trigger = trigger
        return try store.add(draft)
    }

    @Test func addStoresTheTrigger() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store, trigger: .jiraStatus("In Review"))
        let fetched = try #require(try store.get(reminder.id))
        #expect(fetched.trigger == "jira:In Review")
        #expect(fetched.parsedTrigger == .jiraStatus("In Review"))
        #expect(fetched.isWaiting)
        #expect(fetched.firedAt == nil)
    }

    @Test func fireMakesItDueNowWithoutCountingAReschedule() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        try store.markNotified([reminder.id], at: Fixture.now)
        #expect(try store.fire(reminder.id, reason: "!412 merged", at: Fixture.now))
        let fired = try store.require(reminder.id)
        #expect(fired.dueAt == Fixture.now)
        #expect(fired.originalDueAt == Fixture.date("2026-10-06 09:30"))
        #expect(fired.rescheduleCount == 0)
        #expect(fired.notifiedAt == nil)
        #expect(fired.trigger == nil)
        #expect(!fired.isWaiting)
        #expect(fired.firedAt == Fixture.now)
        #expect(fired.firedReason == "!412 merged")
    }

    @Test func fireTwiceIsANoOp() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        #expect(try store.fire(reminder.id, reason: "!412 merged", at: Fixture.now))
        #expect(try !store.fire(reminder.id, reason: "!412 merged", at: Fixture.now.addingTimeInterval(300)))
        #expect(try store.require(reminder.id).firedAt == Fixture.now)
    }

    @Test func aDoneOrDeletedReminderNeverFires() throws {
        let store = try Fixture.store()
        let done = try waiting(store)
        try store.markDone(done.id)
        #expect(try !store.fire(done.id, reason: "x", at: Fixture.now))
        let deleted = try waiting(store)
        try store.delete(deleted.id)
        #expect(try !store.fire(deleted.id, reason: "x", at: Fixture.now))
    }

    @Test func setTriggerReplacesAndRemoves() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        try store.fire(reminder.id, reason: "!412 merged", at: Fixture.now)
        let rearmed = try store.setTrigger(reminder.id, .approved)
        #expect(rearmed.trigger == "approved")
        #expect(rearmed.firedReason == nil)
        #expect(rearmed.firedAt == nil)
        let cleared = try store.setTrigger(reminder.id, nil)
        #expect(cleared.trigger == nil)
        #expect(cleared.dueAt == Fixture.now)
    }

    @Test func resumeMessageLeadsWithTheReason() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("rebase", at: "2026-10-06 09:30")
        draft.resumePrompt = "Rebase feat/x on main"
        let reminder = try store.add(draft)
        #expect(reminder.resumeMessage == "Rebase feat/x on main")
        var fired = reminder
        fired.firedReason = "!412 merged"
        #expect(fired.resumeMessage == "!412 merged. Rebase feat/x on main")
        fired.resumePrompt = nil
        #expect(fired.resumeMessage == "!412 merged")
    }

    @Test func waitingRemindersDueLaterGetTheirOwnBucket() throws {
        let store = try Fixture.store()
        let later = try waiting(store, at: "2026-10-06 09:30")
        let today = try waiting(store, at: "2026-10-01 17:00")
        let plain = try store.add(Fixture.draft("plain", at: "2026-10-06 09:30"))
        #expect(DueBucket.of(later, now: Fixture.now, calendar: Fixture.calendar) == .waiting)
        #expect(DueBucket.of(today, now: Fixture.now, calendar: Fixture.calendar) == .today)
        #expect(DueBucket.of(plain, now: Fixture.now, calendar: Fixture.calendar) == .later)
    }

    @Test func migratesAVersionTwoDatabase() throws {
        let path = Fixture.temporaryDatabasePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path)
        try TicklerDatabase.migrator.migrate(queue, upTo: "v2-resume-prompt")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO reminder (id, title, notes, dueAt, originalDueAt, rescheduleCount, status, source, createdAt, updatedAt)
            VALUES ('abc234', 'old', '', '2026-10-02 08:00:00.000', '2026-10-02 08:00:00.000', 0, 'open', 'human',
                    '2026-10-01 08:00:00.000', '2026-10-01 08:00:00.000')
            """)
        }
        try queue.close()
        let store = try Fixture.store(path: path)
        let old = try store.require("abc234")
        #expect(old.trigger == nil)
        #expect(!old.isWaiting)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TriggerStoreTests`
Expected: build failure, `value of type 'ReminderDraft' has no member 'trigger'`.

- [ ] **Step 3: Add the migration** in `TicklerDatabase.migrator`, after `v2-resume-prompt` and before `return migrator`:

```swift
        migrator.registerMigration("v3-trigger") { db in
            try db.alter(table: "reminder") { table in
                table.add(column: "trigger", .text)
                table.add(column: "firedAt", .datetime)
                table.add(column: "firedReason", .text)
            }
        }
```

- [ ] **Step 4: Extend the model** in `Reminder.swift`. After `public var updatedAt: Date` add:

```swift
    /// The event that makes it due now, as typed (`merged`, `jira:In Review`); nil once fired.
    public var trigger: String? = nil
    public var firedAt: Date? = nil
    /// Why the trigger fired, built from the live data: `!412 merged`.
    public var firedReason: String? = nil

    public var parsedTrigger: Trigger? {
        trigger.flatMap(Trigger.init)
    }

    /// Open and still waiting for its event.
    public var isWaiting: Bool {
        status == .open && trigger != nil
    }

    /// What Resume sends: the reason the trigger fired, then the resume prompt.
    public var resumeMessage: String? {
        guard let firedReason else { return resumePrompt }
        guard let resumePrompt else { return firedReason }
        return "\(firedReason). \(resumePrompt)"
    }
```

In `ReminderDraft`, add `public var trigger: Trigger?` after `externalRef`, a parameter `trigger: Trigger? = nil` at the end of `init`, and `self.trigger = trigger`.

If SwiftLint flags `redundant_optional_initialization` on `= nil`, keep the `= nil` (it gives the memberwise initializer a default, which `ReminderStore.add` relies on) and silence the rule on those three lines with `// swiftlint:disable:next redundant_optional_initialization`.

- [ ] **Step 5: Store writes** in `ReminderStore.swift`.

In `add`, the `Reminder(...)` call gets `trigger: draft.trigger?.rawValue` as its last argument, after `updatedAt: stamp`.

After `delete`, add:

```swift
    /// Sets, replaces or (nil) removes the trigger. A new trigger forgets the previous firing.
    @discardableResult
    public func setTrigger(_ id: String, _ trigger: Trigger?) throws -> Reminder {
        try mutate(id) { reminder, _ in
            reminder.trigger = trigger?.rawValue
            if trigger != nil {
                reminder.firedAt = nil
                reminder.firedReason = nil
            }
        }
    }

    /// Makes a waiting reminder due at `date`. Only an open reminder still waiting changes, so a second firing is a no-op.
    /// Not a reschedule: `rescheduleCount` and `originalDueAt` stay.
    @discardableResult
    public func fire(_ id: String, reason: String, at date: Date) throws -> Bool {
        let stamp = now()
        let changed = try database.pool.write { db in
            try Reminder
                .filter(Column("id") == id && Column("status") == Reminder.Status.open.rawValue && Column("trigger") != nil)
                .updateAll(
                    db,
                    Column("dueAt").set(to: date),
                    Column("notifiedAt").set(to: nil),
                    Column("trigger").set(to: nil),
                    Column("firedAt").set(to: date),
                    Column("firedReason").set(to: reason),
                    Column("updatedAt").set(to: stamp)
                )
        }
        if changed > 0 {
            onChange()
        }
        return changed > 0
    }
```

- [ ] **Step 6: Waiting bucket** in `DueBucket.swift`: add `case waiting` after `case later`, and after `of(_ due:...)`:

```swift
    /// A reminder waiting for an event and not due before tomorrow is shown apart: its date is only the fallback.
    public static func of(_ reminder: Reminder, now: Date, calendar: Calendar = .current) -> DueBucket {
        let bucket = of(reminder.dueAt, now: now, calendar: calendar)
        guard reminder.isWaiting, bucket == .tomorrow || bucket == .later else { return bucket }
        return .waiting
    }
```

Then fix only the switches the new case breaks, so everything still compiles:
- `Sources/TicklerCLI/ReminderTable.swift` `title(_:)`: add `case .waiting: "Waiting"`.
- `App/Sources/Model/Format.swift` `title(for:)`: add `case .waiting: String(localized: "Waiting")`.
- `App/Sources/Views/Theme.swift` `dot(for:soon:)`: change `case .tomorrow, .later:` to `case .tomorrow, .later, .waiting:`.

- [ ] **Step 7: Run the whole suite**

Run: `make test`
Expected: PASS, the 8 new tests included and no existing test broken.

- [ ] **Step 8: Check the app still builds, lint, commit**

```bash
make app
make lint
git add Sources/TicklerCore Sources/TicklerCLI/ReminderTable.swift App/Sources/Model/Format.swift App/Sources/Views/Theme.swift \
  Tests/TicklerCoreTests/TriggerStoreTests.swift
git commit -m "feat(core): store a trigger and fire it once"
```

---

### Task 4: CLI: `--when`, `list --waiting`, JSON, table, resume

**Files:**
- Modify: `Sources/TicklerCLI/AddCommand.swift`
- Modify: `Sources/TicklerCLI/MutationCommands.swift` (`EditCommand`)
- Modify: `Sources/TicklerCLI/ListCommand.swift` (`ListCommand`)
- Modify: `Sources/TicklerCLI/ReminderPresentation.swift` (`ReminderJSON`, `detail`)
- Modify: `Sources/TicklerCLI/ReminderTable.swift:13-15,32` (group by reminder, dim the waiting group)
- Modify: `Sources/TicklerCLI/ResumeCommand.swift:20`
- Test: `Tests/TicklerCLITests/TriggerCLITests.swift`

**Interfaces:**
- Consumes: `Trigger`, `Trigger.defaultDeadline`, `Trigger.usage` (Task 1); `ReminderDraft.trigger`, `ReminderStore.setTrigger`, `Reminder.isWaiting`, `Reminder.resumeMessage`, `DueBucket.of(_ reminder:...)` (Task 3); `LinkExtractor.links(reminderId:notes:explicit:)`; `CLIError.usage` (exit code 2).
- Produces: JSON keys `trigger` (string or null), `waiting` (bool), `firedAt` (`YYYY-MM-DD HH:MM` or null), `firedReason` (string or null).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TicklerCLI

struct TriggerCLITests {
    let mr = "https://gitlab.com/acme/app/-/merge_requests/412"

    @Test func addWithWhenAndNoDateUsesTheDefaultDeadline() throws {
        let object = try CLIHarness().run("add", "rebase", "--link", mr, "--when", "merged", "--json").jsonObject()
        #expect(object["trigger"] as? String == "merged")
        #expect(object["waiting"] as? Bool == true)
        #expect(object["due"] as? String == "2026-10-06 09:30")
        #expect(object["firedAt"] is NSNull)
        #expect(object["firedReason"] is NSNull)
    }

    @Test func addWithWhenAndAt() throws {
        let object = try CLIHarness().run("add", "rebase", "--link", mr, "--when", "approved", "--at", "2026-10-08 10:00", "--json")
            .jsonObject()
        #expect(object["due"] as? String == "2026-10-08 10:00")
        #expect(object["trigger"] as? String == "approved")
    }

    @Test func aTriggerFoundInTheNotesLinkIsAccepted() {
        #expect(CLIHarness().run("add", "rebase", "--notes", "see \(mr)", "--when", "merged").code == 0)
    }

    @Test func addRefusesBadTriggers() {
        let cli = CLIHarness()
        #expect(cli.run("add", "rebase").code == 2)
        #expect(cli.run("add", "rebase", "--link", mr, "--when", "soon").code == 2)
        let unsupported = cli.run("add", "rebase", "--link", mr, "--when", "jira:done")
        #expect(unsupported.code == 2)
        #expect(unsupported.err.contains("jira:done"))
        #expect(cli.run("add", "rebase", "--when", "merged").code == 2)
    }

    @Test func plainReminderJSONHasNullTrigger() throws {
        let object = try CLIHarness().run("add", "Thing", "--at", "2026-10-01 16:00", "--json").jsonObject()
        #expect(object["trigger"] is NSNull)
        #expect(object["waiting"] as? Bool == false)
    }

    @Test func editSetsReplacesAndRemovesTheTrigger() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "rebase", "--link", mr, "--at", "2026-10-02 10:00", "--json").jsonObject()["id"] as? String)
        #expect(try cli.run("edit", id, "--when", "pipeline-green", "--json").jsonObject()["trigger"] as? String == "pipeline-green")
        #expect(cli.run("edit", id, "--when", "jira:done").code == 2)
        let cleared = try cli.run("edit", id, "--when", "", "--json").jsonObject()
        #expect(cleared["trigger"] is NSNull)
        #expect(cleared["waiting"] as? Bool == false)
    }

    @Test func editAtKeepsTheReminderWaiting() throws {
        let cli = CLIHarness()
        let id = try #require(cli.run("add", "rebase", "--link", mr, "--when", "merged", "--json").jsonObject()["id"] as? String)
        let moved = try cli.run("edit", id, "--at", "2026-10-09 09:30", "--json").jsonObject()
        #expect(moved["due"] as? String == "2026-10-09 09:30")
        #expect(moved["trigger"] as? String == "merged")
    }

    @Test func listWaitingShowsOnlyWaitingRemindersAtAnyDate() throws {
        let cli = CLIHarness()
        _ = cli.run("add", "plain", "--at", "2026-10-01 16:00")
        let id = try #require(cli.run("add", "rebase", "--link", mr, "--when", "merged", "--json").jsonObject()["id"] as? String)
        #expect(try cli.run("list", "--waiting", "--json").jsonArray().map { $0["id"] as? String } == [id])
        #expect(try cli.run("list", "--json").jsonArray().count == 1)
    }

    @Test func tableShowsAWaitingGroup() throws {
        let cli = CLIHarness()
        _ = cli.run("add", "rebase", "--link", mr, "--when", "merged")
        let table = try ReminderTable(now: CLIHarness.now, calendar: CLIHarness.calendar, width: 100, color: false)
            .render(cli.store().list(.init(due: .all)))
        #expect(table.contains("Waiting (1)"))
        #expect(!table.contains("Later"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TriggerCLITests`
Expected: FAIL: `add` without `--at` exits 2 (missing option), unknown option `--when`, missing JSON keys.

- [ ] **Step 3: `AddCommand`**. Replace the `at` option and add `when`:

```swift
    @Option(help: "Due date, \"YYYY-MM-DD HH:MM\" in local time. With --when, the fallback deadline (default: 3 working days, 09:30).")
    var at: String?
    @Option(help: "Event that makes it due now: \(Trigger.usage).") var when: String?
```

`validate()` becomes:

```swift
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("the title is empty") }
        guard at != nil || when != nil else { throw ValidationError("pass --at, --when, or both") }
        if let when, Trigger(when) == nil {
            throw ValidationError("--when expects \(Trigger.usage), got \"\(when)\"")
        }
    }
```

`execute` becomes:

```swift
    func execute(_ context: CLIContext) throws {
        let trigger = when.flatMap(Trigger.init)
        let due = try at.map { try context.parseFutureDate($0, flag: "--at") }
            ?? Trigger.defaultDeadline(after: context.now(), calendar: context.calendar)
        let noteText = notes.map(context.readNotes) ?? ""
        if let trigger {
            try requireSupportedLink(trigger, LinkExtractor.links(reminderId: "", notes: noteText, explicit: links))
        }
        let envSession = context.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let sessionId = session ?? envSession
        // A human without a session gets no folder: a cwd alone would offer a Resume that cannot work.
        let folder = cwd ?? (sessionId == nil ? nil : context.currentDirectory)
        let draft = ReminderDraft(
            title: title, notes: noteText, dueAt: due, links: links, sessionId: sessionId, cwd: folder,
            resumePrompt: prompt, source: sessionId == nil ? .human : .claude, trigger: trigger
        )
        let store = try context.openStore(options)
        try context.printResult(store.add(draft), store: store, json: json)
    }
```

And at the end of `AddCommand.swift`, shared with `EditCommand`:

```swift
/// A trigger needs a link it can watch: refused up front rather than waiting forever.
func requireSupportedLink(_ trigger: Trigger, _ links: [ReminderLink]) throws {
    guard links.contains(where: { trigger.supports($0.kind) }) else {
        let kinds = trigger.supports(.jira) ? "a Jira issue" : "a GitLab merge request or a GitHub pull request"
        throw CLIError.usage("--when \(trigger.rawValue) needs \(kinds) among the links")
    }
}
```

- [ ] **Step 4: `EditCommand`**. Add the option, extend `validate`, set the trigger last:

```swift
    @Option(help: "Event that makes it due now: \(Trigger.usage); an empty string removes it.") var when: String?
```

In `validate()`, the first guard becomes `guard title != nil || at != nil || notes != nil || prompt != nil || when != nil` with the message `"nothing to change: pass --title, --at, --notes, --prompt or --when"`, and add:

```swift
        if let when, !when.isEmpty, Trigger(when) == nil {
            throw ValidationError("--when expects \(Trigger.usage), got \"\(when)\"")
        }
```

`execute` becomes:

```swift
    func execute(_ context: CLIContext) throws {
        let store = try context.openStore(options)
        _ = try context.loadReminder(id, from: store)
        let due = try at.map { try context.parseFutureDate($0, flag: "--at") }
        let newNotes = notes.map(context.readNotes)
        let trigger = when.flatMap(Trigger.init)
        // Checked before any write, against the links the edit leaves.
        if let trigger {
            let current = try store.links(for: id)
            let links = newNotes.map { LinkExtractor.links(reminderId: id, notes: $0, explicit: current.map(\.url)) } ?? current
            try requireSupportedLink(trigger, links)
        }
        var updated = try store.update(id, title: title, notes: newNotes, dueAt: due, resumePrompt: prompt)
        if when != nil {
            updated = try store.setTrigger(id, trigger)
        }
        try context.printResult(updated, store: store, json: json)
    }
```

- [ ] **Step 5: `ListCommand`**. Add the flag and filter:

```swift
    @Flag(help: "Only reminders waiting for an event, whatever their date.") var waiting = false
```

In `execute`, replace the `let reminders = ...` line with:

```swift
        let filter = ReminderFilter(due: waiting ? .all : due.filter, status: status.status, project: project)
        let reminders = try store.list(filter).filter { !waiting || $0.isWaiting }
```

- [ ] **Step 6: JSON and plain detail** in `ReminderPresentation.swift`.
- Doc comment: append `` `trigger` (awaited event or null), `waiting` (open and waiting), `firedAt`, `firedReason` (why the trigger fired) `` to the field list.
- Properties: `let trigger: String?`, `let waiting: Bool`, `let firedAt: String?`, `let firedReason: String?`.
- `init`: `trigger = reminder.trigger`, `waiting = reminder.isWaiting`, `firedAt = reminder.firedAt.map { StrictDate.format($0, calendar: context.calendar) }`, `firedReason = reminder.firedReason`.
- `encode(to:)`: add `trigger, waiting, firedAt, firedReason` to the `Key` enum and four `try container.encode(...)` lines (Optional encodes as null through `encode`, as the existing `sessionId` line does).
- `detail(_:links:)`, after the `resume prompt` line:

```swift
        if let trigger = reminder.trigger {
            lines.append("waiting for: \(trigger)")
        }
        if let reason = reminder.firedReason, let firedAt = reminder.firedAt {
            lines.append("fired: \(reason) (\(StrictDate.format(firedAt, calendar: calendar)))")
        }
```

- [ ] **Step 7: Table**. In `ReminderTable.render`, group with `DueBucket.of(reminder, now: now, calendar: calendar)` instead of `DueBucket.of(reminder.dueAt, ...)`, set `let order: [DueBucket?] = [.overdue, .today, .tomorrow, .later, .waiting, nil]`, and make the waiting rows dim: `bucket == .later || bucket == .waiting || bucket == nil ? .dim : .plain`.

- [ ] **Step 8: Resume**. `Sources/TicklerCLI/ResumeCommand.swift:20`: `prompt: reminder.resumePrompt` becomes `prompt: reminder.resumeMessage`. Also check the same file for any other `resumePrompt` read used to describe what was sent, and switch it to `resumeMessage`.

- [ ] **Step 9: Run the whole suite**

Run: `make test`
Expected: PASS, the 9 new tests included. If an existing JSON test compares the full key set, add the four new keys to its expectation.

- [ ] **Step 10: Lint and commit**

```bash
make lint
git add Sources/TicklerCLI Tests/TicklerCLITests/TriggerCLITests.swift
git commit -m "feat(cli): --when on add and edit, list --waiting, trigger fields in JSON"
```

---

### Task 5: App engine: fetch on demand and `TriggerWatcher`

**Files:**
- Modify: `App/Sources/Services/LiveStatusStore.swift` (new `fetchNow`)
- Create: `App/Sources/Services/TriggerWatcher.swift`
- Modify: `App/Sources/Model/AppModel.swift` (`triggerWatcher` property, `start()`, wake observer, `externalChange()`, new `setTrigger`)

**Interfaces:**
- Consumes: `TriggerEvaluator.evaluate`, `Reminder.isWaiting`, `Reminder.parsedTrigger`, `ReminderStore.fire`, `ReminderStore.setTrigger` (Tasks 2 and 3); `LiveStatusStore.supported(_:)`, `LiveStatusFetcher.fetch(_:)`; `AppModel.open`, `links(of:)`, `reload()`, `requestReconcile(catchUp:)`, `perform(_:)`, `store`, `isDemo`.
- Produces: `LiveStatusStore.fetchNow(_ links: [ReminderLink]) async -> [String: LiveStatus]`; `TriggerWatcher.start()`, `TriggerWatcher.check()`; `AppModel.triggerWatcher`; `AppModel.setTrigger(_ id: String, _ trigger: Trigger?)`.

This task is glue over tested units; it is verified by building and by a manual run.

- [ ] **Step 1: `fetchNow`** in `LiveStatusStore`, before `approve`:

```swift
    /// Fetches every supported link now, in parallel, updates the cards, and returns what answered, by URL.
    func fetchNow(_ links: [ReminderLink]) async -> [String: LiveStatus] {
        var targets: [String: LiveTarget] = [:]
        for link in supported(links) {
            targets[link.url] = LiveTarget(link: link)
        }
        let fetcher = fetcher
        let results = await withTaskGroup(of: (String, Result<LiveStatus, Error>).self) { group in
            for (url, target) in targets {
                group.addTask {
                    do {
                        return try await (url, .success(fetcher.fetch(target)))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        var statuses: [String: LiveStatus] = [:]
        for (url, result) in results {
            var entry = entries[url] ?? Entry()
            switch result {
            case let .success(status):
                entry.status = status
                entry.error = nil
                statuses[url] = status
            case let .failure(error):
                entry.error = String(describing: error)
            }
            entry.fetchedAt = Date()
            entries[url] = entry
        }
        return statuses
    }
```

If the compiler complains that `LiveStatusFetcher` or `LiveTarget` is not `Sendable`, add `Sendable` conformance to the type in `Sources/TicklerCore/Live/` (both hold only `Sendable` values) rather than weakening concurrency checks.

- [ ] **Step 2: `TriggerWatcher`**:

```swift
import Foundation
import TicklerCore

/// Fires the triggers of waiting reminders. Runs only while the app does: the deadline covers the rest.
@MainActor
final class TriggerWatcher {
    static let interval: TimeInterval = 300

    private var timer: Timer?
    private var checking = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.triggerWatcher.check() }
        }
        check()
    }

    /// One check at a time: a slow glab must not stack fetches of the same links.
    func check() {
        let model = AppModel.shared
        guard !checking, !model.isDemo, let store = model.store else { return }
        let waiting = model.open.filter(\.isWaiting)
        guard !waiting.isEmpty else { return }
        checking = true
        Task {
            let statuses = await model.liveStatus.fetchNow(waiting.flatMap { model.links(of: $0) })
            var fired = false
            for reminder in waiting {
                guard let trigger = reminder.parsedTrigger,
                      case let .fired(reason) = TriggerEvaluator.evaluate(trigger, links: model.links(of: reminder), statuses: statuses)
                else { continue }
                fired = (try? store.fire(reminder.id, reason: reason, at: Date())) == true || fired
            }
            checking = false
            if fired {
                model.reload()
                // A fired reminder is overdue and not yet notified: the catch-up path notifies it now.
                model.requestReconcile(catchUp: true)
            }
        }
    }
}
```

- [ ] **Step 3: Wire it into `AppModel`**.
- Next to `let liveStatus = LiveStatusStore()` (line 39): `let triggerWatcher = TriggerWatcher()`.
- At the end of `start()`: `triggerWatcher.start()`.
- In the `didWakeNotification` observer, after `requestReconcile(catchUp: true)`: `AppModel.shared.triggerWatcher.check()`.
- In `externalChange()`, check right away when Claude adds or rearms a trigger, instead of waiting up to 5 minutes:

```swift
    private func externalChange() {
        let before = Set((open + done).map(\.id))
        let waitingBefore = Set(open.filter(\.isWaiting).map(\.id))
        reload()
        if preferences.announceNewReminders, !isDemo {
            let added = NotificationPlanner.newlyAdded(previousIds: before, reminders: open)
            Task { await notifications.announce(added) }
        }
        requestReconcile()
        if !Set(open.filter(\.isWaiting).map(\.id)).isSubset(of: waitingBefore) {
            triggerWatcher.check()
        }
    }
```

- Next to `update(...)` in the Actions section:

```swift
    func setTrigger(_ id: String, _ trigger: Trigger?) {
        perform {
            try $0.setTrigger(id, trigger)
            return trigger == nil ? String(localized: "No longer waiting") : nil
        }
    }
```

- [ ] **Step 4: Build**

Run: `make app`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual check** with a Debug build and a GitLab MR that is already merged (glab logged in):

```bash
make dev
MERGED_MR="https://gitlab.com/<a project you can read>/-/merge_requests/<a merged iid>"
tickler add "trigger smoke test" --link "$MERGED_MR" --when merged --json
# within a few seconds: a notification "trigger smoke test", and
tickler list --json
# shows it with "trigger": null, "firedReason": "!<iid> merged", due = now
```

Then delete it with `tickler rm <id>`. If you have no merged MR at hand, report the step as not run instead of skipping it silently.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add App/Sources/Services/LiveStatusStore.swift App/Sources/Services/TriggerWatcher.swift App/Sources/Model/AppModel.swift
git commit -m "feat(app): watch waiting reminders and fire their triggers every 5 minutes"
```

---

### Task 6: App UI: waiting group, trigger row, notification text, resume message

**Files:**
- Modify: `App/Sources/Model/AppModel.swift:246-248` (`nextReminder`), `:290` (window groups), `:374` (resume)
- Modify: `App/Sources/Views/MenuBarContent.swift:144` (popover groups), `:199` (row bucket)
- Modify: `App/Sources/Views/ReminderListView.swift:214` (row bucket)
- Create: `App/Sources/Views/TriggerRow.swift`
- Modify: `App/Sources/Views/ReminderDetailView.swift:35,48` (insert the row), `:196-206` (resume label and help)
- Modify: `App/Sources/Services/NotificationService.swift:156-166` (`content(for:category:)`)
- Modify: `App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `DueBucket.of(_ reminder:...)`, `Reminder.isWaiting`, `Reminder.trigger`, `Reminder.firedReason`, `Reminder.firedAt`, `Reminder.resumeMessage` (Task 3); `AppModel.setTrigger` (Task 5).
- Produces: nothing used by later tasks.

- [ ] **Step 1: Groups and buckets**.
- `AppModel.swift:290`: `DueBucket.of($0.dueAt, now: now, calendar: calendar)` becomes `DueBucket.of($0, now: now, calendar: calendar)`.
- `MenuBarContent.swift:144`: `DueBucket.of($0.dueAt, now: now)` becomes `DueBucket.of($0, now: now)`.
- `MenuBarContent.swift:199` and `ReminderListView.swift:214`: same change for the row bucket (`DueBucket.of(reminder, now: model.now)`), so waiting rows get the dim dot. Leave `ReminderDetailView.swift:124` (`dueChip`) on the date: the chip shows the deadline.
- `nextReminder`: a waiting reminder is not "next" until it fires or its deadline is today:

```swift
    var nextReminder: Reminder? {
        open.first { $0.dueAt >= now && DueBucket.of($0, now: now, calendar: calendar) != .waiting }
    }
```

- [ ] **Step 2: `TriggerRow`**:

```swift
import SwiftUI
import TicklerCore

/// What an event-driven reminder waits for, or why it fired. The live cards below show each link's state.
struct TriggerRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        if reminder.status == .open, let trigger = reminder.trigger {
            HStack(spacing: 8) {
                Label("Waiting for: \(trigger)", systemImage: "hourglass")
                Spacer()
                Button("Stop Waiting") { model.setTrigger(reminder.id, nil) }
                    .buttonStyle(.link)
                    .help("Keep the reminder at its date, without the event")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if reminder.status == .open, let reason = reminder.firedReason {
            Label(reason, systemImage: "bolt.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
```

In `ReminderDetailView.body`, insert `TriggerRow(reminder: reminder)` right before both `LiveStatusSection(reminder: reminder)` lines (35 and 48).

- [ ] **Step 3: Resume message**.
- `AppModel.swift:374`: `let prompt = reminder.resumePrompt` becomes `let prompt = reminder.resumeMessage`.
- `ReminderDetailView.swift:196-206`: replace `reminder.resumePrompt` with `reminder.resumeMessage` in the `if let prompt` label and in `.help(...)`.

- [ ] **Step 4: Notification text** in `NotificationService.content(for:category:)`, replace the `content.body = ...` line:

```swift
        // The reason leads only on the firing itself; a later reschedule notifies like any reminder.
        let lead: String? = if let trigger = reminder.trigger {
            String(localized: "Still waiting: \(trigger)")
        } else if let reason = reminder.firedReason, reminder.firedAt == reminder.dueAt {
            reason
        } else {
            nil
        }
        content.body = [lead, Format.preview(reminder.notes)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
```

- [ ] **Step 5: French strings**. Add the six keys with this script (it keeps the catalog's existing format and key order):

```bash
python3 - <<'PY'
import json
path = "App/Resources/Localizable.xcstrings"
with open(path, encoding="utf-8") as f:
    catalog = json.load(f)
for key, fr in {
    "Waiting": "En attente",
    "Waiting for: %@": "En attente de : %@",
    "Stop Waiting": "Ne plus attendre",
    "Keep the reminder at its date, without the event": "Garder le rappel à sa date, sans l'événement",
    "Still waiting: %@": "Toujours en attente : %@",
    "No longer waiting": "Plus en attente",
}.items():
    catalog["strings"][key] = {"localizations": {"fr": {"stringUnit": {"state": "translated", "value": fr}}}}
catalog["strings"] = dict(sorted(catalog["strings"].items(), key=lambda kv: kv[0].lower()))
with open(path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))
    f.write("\n")
PY
git diff --stat App/Resources/Localizable.xcstrings
# expected: only additions; if the diff rewrites unrelated lines, revert and match the file's existing indent and separators
```

- [ ] **Step 6: Build and look at it**

```bash
make dev
tickler add "rebase on main" --link "https://gitlab.com/gitlab-org/gitlab/-/merge_requests/1" --when merged --at "2026-10-09 09:30"
# expected: a "Waiting" group in the popover and the window, not counted in the badge;
# the detail pane shows "Waiting for: merged" and Stop Waiting moves it back to "Later"
```

Debug builds can write PNGs of their windows with `TICKLER_SNAPSHOT=<dir>`: attach one of the detail pane to the task report. Then remove the reminder with `tickler rm <id>`.

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add App/Sources App/Resources/Localizable.xcstrings
git commit -m "feat(app): waiting group, trigger row and fired reason in notifications"
```

---

### Task 7: Skill and README

**Files:**
- Modify: `skills/tickler/SKILL.md`
- Regenerate: `Sources/TicklerCore/Skill/SkillContent.swift` (via `scripts/embed-skill.sh`)
- Modify: `README.md` (CLI table, JSON section, App table)

**Interfaces:**
- Consumes: the CLI surface of Task 4.
- Produces: nothing.

- [ ] **Step 1: Skill**. In `skills/tickler/SKILL.md`:
- Command table: change the `add` row to `` `tickler add "<title>" --at "YYYY-MM-DD HH:MM" [--when <event>] [--notes -] [--link <url>]... [--prompt "<text>"]` ``, and add a row `` | `tickler list --waiting --json` | Reminders waiting for an event, whatever their date | ``.
- JSON fields sentence: add `` `trigger` (awaited event or null), `waiting`, `firedAt`, `firedReason` (why the event fired) ``.
- New section after "Creating", titled `## Waiting for an event`:

```markdown
## Waiting for an event

When the action depends on an event rather than a time, pass `--when` with the link it watches. Tickler.app checks every 5 minutes; when the event happens, the reminder becomes due now and notifies, with the reason first in the resume message. It is never marked done for you.

| The user says | Pass |
|---|---|
| "quand la MR est mergée", "once it's merged" | `--when merged` |
| "dès que la pipeline passe" | `--when pipeline-green` |
| "préviens-moi si la pipeline casse" | `--when pipeline-failed` |
| "quand j'ai les approvals" | `--when approved` |
| "quand PE-1685 est Done", "when it moves to In Review" | `--when jira:done`, `--when "jira:In Review"` |
| "si c'est pas mergé d'ici jeudi" | `--when merged --at "<thursday> 09:30"` |

- The link must be on the reminder (`--link` or in the notes): MR or PR for `merged`, `pipeline-*` and `approved`, a Jira issue for `jira:*`. With several, all must reach the state, except `pipeline-failed`, which fires on the first failure.
- Without a stated deadline, omit `--at`: the CLI sets 3 working days at 09:30. Do not invent one.
- The event fires only while Tickler.app runs; the deadline is the safety net.
- At check time, a reminder with `firedReason` set says what happened: start from it.
```

- Follow-up table, the row about opening an MR: offer `--when approved` (to merge it) instead of chasing the review after a delay, and keep the dated chase when the project has no approval rule.

- [ ] **Step 2: Embed and verify**

```bash
scripts/embed-skill.sh
# expected: embedded skills/tickler/SKILL.md into Sources/TicklerCore/Skill/SkillContent.swift
swift test --filter SkillVersionTests
# expected: PASS
```

- [ ] **Step 3: README**.
- CLI table: `add` row gets `` `--when <event>` (`merged`, `pipeline-green`, `pipeline-failed`, `approved`, `jira:done`, `jira:<status>`; without `--at`, the deadline is 3 working days at 09:30) ``; `edit` row gets `` `--when <event>` (`""` removes it) ``; `list` row gets `` `--waiting` ``.
- JSON example: add `"trigger": null`, `"waiting": false`, `"firedAt": null`, `"firedReason": null` in sorted position, and one line under it: `` `trigger` is the awaited event; once it fires, `firedReason` says why (`!412 merged`) and the reminder is due at `firedAt`. ``
- App table: in the Window row, add `Waiting` to the groups; add a row `| Triggers | Every 5 minutes while the app runs, reminders waiting for an event check their links; when it happens the reminder becomes due now and notifies with the reason. **Stop Waiting** in the detail pane keeps the date and drops the event |`.

- [ ] **Step 4: Lint and commit, one scope each**

```bash
make lint
git add skills/tickler/SKILL.md Sources/TicklerCore/Skill/SkillContent.swift
git commit -m "docs(skill): reminders that wait for an MR, pipeline or ticket event"
git add README.md
git commit -m "docs(readme): --when, list --waiting and the trigger fields"
git log --format="%h %G? %s" origin/main..HEAD
# expected: every line shows G
```
