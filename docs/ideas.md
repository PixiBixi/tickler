# Ideas

Features considered but not scheduled. Each one goes through a spec in `docs/superpowers/specs/` before any code.

## Recurrence

`--every weekday 09:00`, `--every monday`: marking the reminder done creates the next occurrence. Covers daily checks that today have to be recreated by hand. Touches the model (one field), `done`, the skill and the app.

## Procrastination signal

`rescheduleCount` is already stored. Past a threshold (3 reschedules), the session digest and the app flag the reminder and suggest doing, delegating or dropping it.

## Review inbox

A watcher that creates a reminder when an MR or PR is assigned to the owner for review, instead of creating it by hand.

## Slack trigger

A reminder that fires when someone replies in a Slack thread. Needs a token and polling: the most expensive of the list.

## Next session in the repository

`--when session:here`: the reminder becomes due at the next Claude Code session opened in that repository, instead of a date. For "when I pick this topic up again". The SessionStart hook already resolves the repository (`GitRoot`).

## Done on event

`--done-when merged`: the reminder closes itself when the event fires instead of notifying, for "check the MR got merged" reminders that only need ticking. Reuses `TriggerWatcher` and `ReminderStore.fire`.

## Hold notifications during meetings

A notification due during a busy calendar event waits for the event to end. Calendar access is already granted; touches `NotificationPlanner`.

## New review threads trigger

`--when new-thread`: due when the unresolved discussion count of an MR goes up. The live status already reads it.

## Quick add from the clipboard

The global shortcut prefills the link when the clipboard holds an MR, PR or Jira URL that `LiveTarget` accepts.

## Metric follow-up

A reminder carrying a PromQL query: at the due date the card shows the value before and after, for the performance or cost check after a rollout. Needs `gcx` or a Prometheus endpoint, the most work of these.

## Spec drift

`docs/superpowers/specs/2026-10-06-tickler-session-start-hook-design.md` still shows the first digest format (ids as links, an "Elsewhere" line counting only overdue reminders). Update it to linked titles, the terminal summary and "due within the hour".
