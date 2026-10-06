# Tickler: notes for Claude

Usage, layout and `make` targets are in the README. This file only lists the traps that keep coming back.

## Gates

- `make test` builds only the SwiftPM package. App code (`App/`) compiles only with `make app`: run it whenever a core type the app switches on changes (a new `DueBucket` case breaks `Format.title` and `Theme.dot`).
- SwiftLint runs strict: line length 140, cyclomatic complexity 15. A switch over several status kinds goes over 15 quickly, so write one private helper per case from the start. SwiftFormat removes redundant `return` and prefers switch expressions.
- `Sources/TicklerCore/Skill/SkillContent.swift` is generated: edit `skills/tickler/SKILL.md`, then run `scripts/embed-skill.sh`.
- To try a branch, use `.build/debug/tickler` and `make dev`: the `tickler` on PATH is the Homebrew release and lacks new flags.

## Text that reaches Claude

`Reminder.resumeMessage` (the reason a trigger fired, then the resume prompt) is sent or typed into a Claude Code session as a prompt.

- Build it only from fixed strings, validated ids (`LiveTarget` keys and numbers) and what the user typed. Never interpolate text returned by `glab`, `jira` or `gh` (status names, titles, even the issue key from the JSON response).
- It must never start with `!` (Claude Code bash mode) or `/` (slash command): prefix the kind, as in `MR !412 merged`.

## Keeping two paths in sync

- A check made before a write must reuse the code the write runs: the `edit --when` link check and `ReminderStore.update` share `LinkExtractor.linksAfterNotesChange`.
- A notification request id must change whenever anything baked into its content changes (due date, trigger), or macOS keeps showing the stale text: see `NotificationPlanner.requestId`.
- A conditional write decided on data read earlier must filter on that data: `ReminderStore.fire` takes the trigger it evaluated.

## Swift 6 and processes

- Deployment target is macOS 14: `Mutex` is unavailable, use `OSAllocatedUnfairLock`. `TaskGroup.reduce(into:)` fails strict concurrency ("sending group"), collect with `for await`.
- Every external tool call needs a timeout (`ProcessOutcome.run`, 60 s), and pipes must be drained while the process runs. Throw `LiveError.timedOut`, not `.failed`: the jira runner retries `.failed` through the login shell, which doubles the wait.
