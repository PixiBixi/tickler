# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Tickler is a macOS reminder tool driven by Claude Code: a CLI (`tickler`) that Claude calls, a SwiftUI menu bar app (`Tickler.app`) that notifies and resumes the Claude session, and a skill (`skills/tickler/SKILL.md`) that teaches Claude when to create reminders. The README is the usage reference (commands, flags, JSON shape); feature designs live in `docs/superpowers/specs/`, their plans in `docs/superpowers/plans/`.

## Commands

| Command | Does |
|---|---|
| `make test` | `swift test`: the SwiftPM package only (core and CLI), Swift Testing |
| `swift test --filter TriggerEvaluatorTests` | One suite; `--filter 'TriggerTests/parsesEveryForm'` for one test |
| `make lint` | SwiftLint `--strict` and `swiftformat --lint` (`make format` applies SwiftFormat) |
| `make app` | Generates `Tickler.xcodeproj` from `project.yml` (XcodeGen) when needed, builds the app; the only way to compile `App/` |
| `make dev` | Debug app build, replaces `~/Applications/Tickler.app`, relaunches it |
| `.build/debug/tickler <cmd>` | The branch's CLI; the `tickler` on PATH is the Homebrew release |
| `TICKLER_DB=<path>` | Points CLI and app at another SQLite file |

Lefthook runs SwiftFormat, SwiftLint, gitleaks, markdownlint and actionlint on commit, and checks Conventional Commits; on push it runs `swift test`, and `make app` when `App/`, the core or `project.yml` changed. Releases: `scripts/bump.sh` (cocogitto writes `CHANGELOG.md`, never edit it by hand).

## Architecture

Three products share one library, `Sources/TicklerCore`:

- **One SQLite file is the source of truth** (`~/Library/Application Support/Tickler/tickler.sqlite`, GRDB, WAL, migrations in `TicklerDatabase.migrator`). The CLI writes to it directly, so it works with the app closed, then posts the Darwin notification `io.github.pixibixi.tickler.changed` (`ChangeNotifier`). The app observes it, reloads, and reconciles; it also reloads every minute and on wake. Every read and write goes through `ReminderStore`.
- **Planners are pure functions** (`Sources/TicklerCore/Planning/`): `NotificationPlanner` and `CalendarPlanner` take the open reminders plus what is already scheduled and return what to add and remove. `AppModel.requestReconcile` serializes the runs and applies them through `NotificationService` (UserNotifications) and the EventKit sync. A notification request id is `<id>@<tag>@<dueEpoch>`, so a reschedule replaces it. Catch-up of missed notifications runs only at start and on wake.
- **Live status** (`Sources/TicklerCore/Live/`): `LiveTarget` validates a link into strict parts, `LiveStatusFetcher` runs `glab`, `jira` or `gh` with them as arguments (never interpolated) and `LiveStatusParser` decodes the JSON. The app runs tools through the login shell (`AppToolRunner`, `LoginShellRunner`) because a Finder-launched app has no shell PATH or tokens; the CLI runs them directly. Live data stays in memory (`App/Sources/Services/LiveStatusStore.swift`), never in the database.
- **Event triggers**: a reminder with a `trigger` waits for an event on its links. `TriggerWatcher` (app only, every 5 minutes, on wake and when a waiting reminder appears) fetches statuses, `TriggerEvaluator` decides, `ReminderStore.fire` makes the reminder due now; the existing catch-up then notifies it. The due date stays as the fallback deadline.
- **Session resume** (`Sources/TicklerCore/Resume/`): `SessionResumer` finds a running `claude` session in the process table (`ProcessInspector`), focuses its tab through a terminal driver (WezTerm CLI, AppleScript for iTerm2 and Ghostty), or reopens it with `claude --resume` in the reminder's folder. `Reminder.resumeMessage` is the first message sent.
- **CLI** (`Sources/TicklerCLI`, swift-argument-parser): every command gets a `CLIContext` carrying the clock, environment, stdin, stdout and the tool runner. Tests run commands in process through `CLIHarness` with a fixed clock (Thursday 2026-10-01 10:45, Europe/Paris) and a temporary database; core tests use the same clock via `Fixture`.
- **App** (`App/`, not in Package.swift): `AppModel` is the main-actor singleton holding the open and done reminders, the derived groups (`DueBucket.of(reminder)`) and every action. The `tickler://open/<id>` URL scheme opens a reminder (calendar events and CLI ids link to it).

## Gates and generated files

- `make test` never compiles `App/`: run `make app` whenever a core type the app uses changes (a new `DueBucket` case breaks `Format.title` and `Theme.dot`).
- SwiftLint runs strict: line length 140, cyclomatic complexity 15. A switch over several status kinds goes over 15 quickly, so write one private helper per case from the start. SwiftFormat removes redundant `return` and prefers switch expressions.
- `Sources/TicklerCore/Skill/SkillContent.swift` is generated: edit `skills/tickler/SKILL.md`, then run `scripts/embed-skill.sh`. The skill ships inside the binary and `tickler skill install` copies it to `~/.claude/skills/tickler`.
- App strings are English with French translations in `App/Resources/Localizable.xcstrings`; CLI output is English only.

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
