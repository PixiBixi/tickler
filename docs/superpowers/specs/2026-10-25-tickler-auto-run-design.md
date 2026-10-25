# Tickler design: run the resume prompt in the background

Date: 2026-10-25. Status: design agreed in conversation from a mockup; the owner asked to build it.

## Goal

Many reminders are verification prompts: rerun a script, read metrics, compare against a baseline (PE-1873: "re-mesure !991 sur 5 jours"). Today the reminder notifies, the owner clicks "Reprendre", a terminal opens, and they wait for Claude to finish. Clicking adds nothing. An auto-run reminder instead runs its resume message in the linked Claude session in the background when it becomes due, and notifies once Claude has answered, with a verdict a human reads in one line. The full answer is in the reminder; "Rouvrir" continues the same session in a terminal.

An auto-run never marks a reminder done: the owner reads the verdict and ticks it, or continues in the terminal.

## Scope

- Opt-in per reminder, off by default, two modes: `read` (default) and `write`.
- Runs in Tickler.app only, like triggers. With the app closed at the due date, the run starts at the next launch or wake (same catch-up as notifications).
- Starts when the reminder becomes due: at its due date, or when its trigger fires (a fired trigger makes it due now). "Lancer maintenant" and "Relancer" start one by hand.
- CLI: `add --auto-run`, `edit --auto-run`, JSON fields, the last run in `show`.
- App: option in the detail pane and quick add, running state, result block, run history, notification, list icon.
- Skill: when to offer `--auto-run`.

Out of scope: recurring runs (a reminder runs once per due date; "Relancer" reruns), streaming progress while it runs, `bypassPermissions` or any mode that skips the owner's permission rules, running from the CLI without the app, posting the result anywhere else (Jira, Slack).

## How a run works

The app runs, in the reminder's `cwd`, through a new runner built like `SessionResumer.resumeCommand`: `env -u <the same scrubbed CLAUDE_* variables> zsh -lic 'exec claude "$@"' claude <args>`, so `claude` has the owner's PATH (`~/.local/bin` included) and credentials, with the arguments as positional parameters. `AppToolRunner` is not reused: its fixed search path misses `~/.local/bin`, and it has no working directory, no stderr and no cancellation.

```
claude -p --resume <sessionId> --output-format json \
  --permission-mode <dontAsk | acceptEdits> --permission-prompts none \
  -- "<resumeMessage>\n\n<REPORT_FORMAT>"
```

- Arguments are passed as an argv array, never interpolated into a shell string (same rule as `LiveStatusFetcher`).
- Without `sessionId`, `--resume` is dropped and a new session starts in `cwd`; the `session_id` from the JSON is then stored on the reminder so "Rouvrir" works. Without `cwd`, auto-run is refused (CLI exit code 2, toggle disabled in the app).
- `read` maps to `dontAsk`: only what the owner's settings already allow runs, everything else is denied. `write` maps to `acceptEdits`: file edits are allowed too. `--permission-prompts none` in both: nothing ever waits for an answer.
- Timeout 30 minutes, then the process is terminated. Pipes are drained while it runs (as `ProcessOutcome.run` does); the runner keeps the `Process` handle so "Arrêter" can terminate it, and returns stdout, stderr and the exit status.
- A session open in a terminal right now (`SessionResumer.runningSessions`) is not run in the background: two writers on one transcript would conflict. The run is `skipped` and the reminder notifies as a plain one, saying "Session ouverte, lancement manuel". Our own `claude -p --resume` children also show up as resumed sessions: `AutoRunner` subtracts the sessions it is running itself before that check, and the detail pane shows "En cours" rather than "Ouverte" for them.
- One run at a time per session: a reminder whose session is already being auto-run by another reminder waits for that run to end, then starts. Reminders on different sessions run in parallel.
- Marking the reminder done or deleting it terminates its running process; the run ends `cancelled` (or disappears with the reminder).

`REPORT_FORMAT` is a fixed English string in `TicklerCore`, appended to the prompt after a blank line (not as a system prompt: `--system-prompt-snapshot` reuses the first request's system prompt on every resume, so an appended one is ignored). The prompt still starts with the owner's text. It asks Claude to end its answer with:

```
Verdict: OK | WATCH | KO - one sentence
Key figures:
- 3 to 5 lines, before -> after
Next step: the next action, or "none"
```

## Reading the result

`claude -p --output-format json` prints one JSON object. `AutoRunParser` (pure, `TicklerCore`) reads `result` (Claude's final message), `session_id`, `is_error`, `duration_ms`, `total_cost_usd` and the count of `permission_denials` (shown as "N actions refusées" in the result block, the usual sign a read-mode run needed more rights); it never shows the raw JSON. From `result` it extracts the report block:

- `verdict`: `ok`, `watch` or `ko` from the `Verdict:` line, case-insensitive; `unknown` if the line is missing.
- `headline`: the text after the verdict word on that line.
- `figures` and `nextStep`: the lines under their headings.
- The full `result` text is kept as is, Markdown.

A missing or malformed block is not a failure: the run succeeds with verdict `unknown`, the notification shows the first line of `result`, the detail pane shows the full text.

Failures: non-zero exit, `is_error`, unparsable JSON, timeout, `claude` not found. The run is `failed` with a short English error built by Tickler (`Timed out after 30 min`, `claude exited with status 1`) plus the last 20 lines of stderr shown in the detail pane only.

The result text comes from Claude and is shown to the owner; it is never sent to Claude as a prompt and never enters `resumeMessage` or the SessionStart digest.

## Data

Migration `v4-auto-run`:

| Change | Holds |
|---|---|
| `reminder.autoRun` text, nullable | `read`, `write`, or nil for a plain reminder |
| table `run` | One row per run, foreign key to `reminder` with cascade delete |

`run` columns: `id`, `reminderId`, `forDueAt` (the reminder's `dueAt` when the run started), `sessionId`, `mode`, `startedAt`, `endedAt`, `state` (`running`, `succeeded`, `failed`, `cancelled`, `skipped`), `verdict`, `headline`, `figures` (JSON array), `nextStep`, `output` (full `result`), `error`, `denials`, `costUsd`, `durationMs`.

`ReminderStore` gains `startRun`, `finishRun`, `runs(for:)`, `lastRun(for:)`. `startRun` refuses when the reminder already has a `running` row. At app start, `running` rows with no process (the app quit or crashed during a run) become `failed` with "Interrupted".

A reminder has run for its current due date when any run, whatever its state, has `forDueAt` equal to its `dueAt`. So "Lancer maintenant" before the due date covers that date (no second run when it falls due), "Arrêter" does not restart it (the reminder then shows the plain "Reprendre"), and rescheduling or a fired trigger moves `dueAt`, so the new date runs again. "Relancer" always starts a new run.

## Engine

| Unit | Where | Does |
|---|---|---|
| `AutoRunMode` | `Sources/TicklerCore/AutoRun/` | `read`/`write`, parsing, the permission mode it maps to |
| `AutoRunCommand` | `Sources/TicklerCore/AutoRun/` | Pure: builds the argv from the reminder (session, cwd, mode, message) |
| `AutoRunParser` | `Sources/TicklerCore/AutoRun/` | Pure: JSON and report block to a `RunResult` |
| `AutoRunPlanner` | `Sources/TicklerCore/Planning/` | Pure: from open reminders, their last runs and now, which reminders to start |
| `AutoRunner` | `App/Sources/Services/` | Glue: runs the planner on reconcile and on a timer at the next due date, checks live sessions minus its own, runs the process off the main actor, writes the run, posts the notification, reloads |

`NotificationPlanner` no longer schedules the due notification of a reminder with `autoRun` set: the runner notifies when the run ends. Catch-up skips them the same way. A skipped run (live session) or a failed run falls back to a plain notification, so the owner is always told. A run's notification uses its own id, `<reminderId>@run@<runId>`: `reminderId(fromRequestId:)` keeps working (first `@` field), it is never a pending request (posted immediately) so `plan` ignores it, and `staleDelivered` must keep it while the reminder is open.

When a run ends, `notifiedAt` is set: the reminder is overdue but already notified.

## Notification

- Title: `<title>` truncated, prefixed by the verdict mark (✅ OK, 👀 WATCH, ❌ KO, ⚪ unknown, ⚠️ failed).
- Body: the headline, or the error for a failed run.
- Actions: "Voir le résultat" (opens `tickler://open/<id>`) and "Terminé"; for a failed or skipped run, "Reprendre" (the existing resume) and "Relancer".

## CLI

| Command | Change |
|---|---|
| `tickler add ... --auto-run [read\|write]` | Requires `--prompt` and a cwd (given or taken from the session); exit code 2 otherwise |
| `tickler edit <id> --auto-run read\|write\|off` | Sets or removes it |
| `tickler show <id>` | A "Last run" section: state, verdict, headline, figures, next step, time and cost |
| JSON | `autoRun` (string or null), `lastRun` (object or null: `state`, `verdict`, `headline`, `figures`, `nextStep`, `startedAt`, `endedAt`) |

The CLI never starts a run.

## App

Following the mockup:

- Quick add and detail pane: under the resume prompt, a toggle "Lancer automatiquement à l'échéance" and a segmented control "Lecture seule / Peut modifier"; disabled without a resume prompt or a folder.
- Detail pane, before the due date: an "AUTO · lecture seule" pill next to the date; primary button "Lancer maintenant", "Reprendre dans le terminal" stays.
- While running: the Claude session panel shows "En cours · <elapsed>" with "Arrêter" (terminates the process, run `cancelled`).
- After a run: a "Résultat" block above the notes, tinted by verdict, with the headline, key figures, next step, and the full answer folded below (Markdown, through the existing notes renderer). Primary buttons become "Continuer dans le terminal", "Terminé", "Relancer". A "Runs" list in the side column (time, verdict, duration).
- List and menu bar: an icon in place of the dot: scheduled auto-run, running, then the verdict colour.
- English and French strings in `Localizable.xcstrings`.

## Skill

- Offer `--auto-run` when the resume prompt is a check that only reads (rerun a measurement, read a dashboard, compare to a baseline); never by default.
- `write` only when the owner asked for Claude to change things unattended.
- Write the resume prompt so it stands alone: the run has no one to answer a question.

## Testing

- `AutoRunCommand`: argv for both modes, with and without session, message starting with `-`.
- `AutoRunParser`: real `claude -p --output-format json` fixtures (success, `is_error`), report block present, missing, partial, lowercase verdict, French text around it.
- `AutoRunPlanner`: due now, already ran for this due date, rescheduled, fired trigger, running, done reminder.
- `NotificationPlanner`: no due notification for auto-run reminders.
- Store: migration from a v3 database, one running row per reminder, interrupted runs at start, cascade delete.
- CLI: `--auto-run` refusals, `edit --auto-run off`, JSON and `show`.
- `AutoRunner` is glue, checked by hand in a Debug build on a real session (PE-1873 style check in read mode, and a denied write in read mode).
