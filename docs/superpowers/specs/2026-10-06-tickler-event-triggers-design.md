# Tickler design: reminders triggered by an event

Date: 2026-10-06. Status: design agreed in conversation; the owner asked to build it without pushing.

## Goal

Many follow-ups have no natural date: "rebase once Paul's MR is merged", "merge once the pipeline is green", "turn the flag on when PE-1685 is Done". Today Claude guesses a date, which fires too early or too late, or the owner polls by hand. A reminder can now wait for an event on one of its links; when the event happens, the reminder becomes due now and notifies like any other.

A trigger never marks a reminder done: the event is the signal to act, not proof the work is done. Auto-closing finished reminders is a separate feature.

## Scope

- One trigger per reminder, among: `merged`, `pipeline-green`, `pipeline-failed`, `approved`, `jira:done`, `jira:<status name>`.
- The due date stays mandatory and is the fallback deadline: if the event never comes, the reminder notifies at that date as today.
- Evaluation runs in Tickler.app only, every 5 minutes, from the live data `glab`, `jira` and `gh` already return. The CLI has no daemon: with the app closed nothing fires, the deadline still does.
- CLI: `add --when`, `edit --when`, `list --waiting`, new JSON fields.
- App: display only (waiting group, trigger state in the detail pane, reason in the notification, remove the trigger). No trigger picker in quick add: Claude creates these reminders.
- Skill: when to use `--when` rather than `--at`, default deadline, the MR follow-up uses `--when approved`.

Out of scope: `threads-opened` and any trigger on a transition rather than a state (it would need the previous live state in the database, which V2 deliberately keeps in memory only), several triggers on one reminder, Slack, auto-done.

## Triggers

| Trigger | GitLab MR | GitHub PR | Jira issue |
|---|---|---|---|
| `merged` | `state` is `merged` | `state` is `MERGED` | - |
| `pipeline-green` | `pipeline` is `success` | checks: at least one, none failed, none pending | - |
| `pipeline-failed` | `pipeline` is `failed` | checks: `failed > 0` | - |
| `approved` | `approvalsGiven >= max(approvalsRequired, 1)` | `reviewDecision` is `APPROVED` | - |
| `jira:done` | - | - | status category `done` |
| `jira:<name>` | - | - | status name equals `<name>`, case-insensitive |

Rules:

- A trigger applies to every link it supports: `merged`, `pipeline-*` and `approved` to GitLab MRs and GitHub PRs, `jira:*` to Jira issues. `tickler add` and `edit` refuse a trigger with no supported link (exit code 2).
- With several supported links, the trigger fires when all of them satisfy it, so two linked MRs plus `merged` fire once both are merged. `pipeline-failed` is the exception: the first failure fires.
- An MR or PR that is closed or merged satisfies any MR/PR trigger, with a reason saying so ("!412 closed without merge"): otherwise the reminder would wait for an event that can no longer happen.
- A link whose status is unknown (fetch failed, tool disabled in Settings) counts as not satisfied, except for `pipeline-failed` where it is simply ignored.

## Data

Migration `v3-trigger` adds three nullable columns to `reminder`:

| Column | Holds |
|---|---|
| `trigger` | The trigger as typed, `merged` or `jira:In Review`; nil once fired or for a plain reminder |
| `firedAt` | When the trigger fired |
| `firedReason` | Short English text built from the live data: `!412 merged`, `PE-1685 is Done`, `#88 pipeline failed` |

`Trigger` in `TicklerCore` parses and prints that string (`enum Trigger { merged, pipelineGreen, pipelineFailed, approved, jiraDone, jiraStatus(String) }`), and says which link kinds it supports.

A reminder is waiting when it is open and `trigger` is not nil.

## Engine

| Unit | Where | Does |
|---|---|---|
| `Trigger` | `Sources/TicklerCore/Triggers/` | Parsing, printing, supported link kinds |
| `TriggerEvaluator` | `Sources/TicklerCore/Triggers/` | Pure: `evaluate(trigger, statuses: [ReminderLink: LiveStatus?]) -> .waiting or .fired(reason)`, the rules above |
| `ReminderStore.fire(_:reason:at:)` | `Sources/TicklerCore/Store/` | In one write, only while `trigger IS NOT NULL`: `dueAt = at`, `notifiedAt = nil`, `trigger = nil`, `firedAt`, `firedReason`. `rescheduleCount` and `originalDueAt` are untouched: firing is not a reschedule. Returns whether a row changed, so a second firing is a no-op |
| `TriggerWatcher` | `App/Sources/Services/` | Every 5 minutes, on wake and when a reminder with a trigger appears: collects the supported links of waiting reminders, fetches each URL once through `LiveStatusStore` (so the detail pane reuses the result), evaluates, fires, then reloads |

After a firing, the reminder is overdue with no `notifiedAt`: the existing catch-up path notifies it right away, and the existing planners replace the pending notification at the old deadline and move the calendar event, as they do for a reschedule.

Failures: a failing tool leaves the reminder waiting, the error shows in the detail pane, the next tick retries. Ticks do not overlap: a tick still running skips the next one.

## CLI

| Command | Change |
|---|---|
| `tickler add ... --when <trigger>` | `--at` becomes optional with `--when`: the default deadline is 3 working days later (Monday to Friday) at 09:30 |
| `tickler edit <id> --when <trigger>` | Sets or replaces the trigger; `--when ""` removes it |
| `tickler list --waiting` | Only waiting reminders, any due date |
| `tickler list` (table) | A "Waiting" group for waiting reminders due tomorrow or later; due today or overdue, they stay in those groups |
| JSON | `trigger` (string or null), `waiting` (bool), `firedAt`, `firedReason` |

## Resume

When `firedReason` is set, the prompt sent on resume is `"<firedReason>. <resumePrompt>"`, or the reason alone without a resume prompt: "!412 merged. Rebase feat/x on main".

## App

- Menu bar popover and window list: a "Waiting" group, same rule as the CLI table. The badge is unchanged: it counts today and overdue, so a waiting reminder only counts once its deadline is reached or it fired.
- Detail pane: "Waiting for: merged" with the current state of each supported link, taken from the live status cards already shown, and a button that removes the trigger (the reminder keeps its date).
- Notification: the body starts with the reason ("!412 merged"); a reminder reaching its deadline while still waiting says "Still waiting: merged".
- English and French strings in `Localizable.xcstrings`.

## Skill

- Use `--when` when the user ties the action to an event ("quand la MR est mergée", "once the pipeline passes"), `--at` for a time, both for "if not merged by Thursday".
- Without a stated deadline, let the CLI default apply rather than inventing one.
- After opening an MR, offer `--when approved` (merge it) instead of "chase the review in 2 days"; keep the dated follow-up when no approval rule exists.
- Document the new JSON fields for the morning check: a fired reminder carries `firedReason`.

## Testing

- `Trigger`: round trip of every form, invalid strings, supported link kinds.
- `TriggerEvaluator`: every row of the trigger table on the existing `LiveStatusParser` fixtures, all-links and any-link semantics, closed MR or PR, unknown statuses.
- Store: migration from a v2 database, `fire` sets the fields and is idempotent, `edit --when ""`.
- CLI: refusal without a supported link, default deadline across a weekend, `list --waiting`, JSON fields.
- Resume prompt composition.
- `TriggerWatcher` is thin glue over tested units; checked by hand in a Debug build with a real MR.
