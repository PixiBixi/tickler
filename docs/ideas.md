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

## Spec drift

`docs/superpowers/specs/2026-10-06-tickler-session-start-hook-design.md` still shows the first digest format (ids as links, an "Elsewhere" line counting only overdue reminders). Update it to linked titles, the terminal summary and "due within the hour".
