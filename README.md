# Tickler

Reminders that Claude Code writes for you, with a macOS menu bar app that notifies you on time and brings the Claude session back in one click.

- `tickler`: the CLI Claude uses to add, list and close reminders (JSON output).
- `Tickler.app`: menu bar item with a badge, a window filtered by date, notifications with actions (resume the session, snooze, reschedule, done, open the ticket or Slack thread), and a one-way copy of every reminder into a calendar of your choice.

Both share one SQLite file: `~/Library/Application Support/Tickler/tickler.sqlite`. The CLI works while the app is closed; the app picks up its changes instantly.

Requirements: macOS 14 or later, Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [WezTerm](https://wezterm.org) for session resume.

## Install

```bash
brew install xcodegen
make install
# Installs ~/.local/bin/tickler and ~/Applications/Tickler.app
open ~/Applications/Tickler.app
```

The app is ad-hoc signed by default, so macOS may ask for the calendar and notification permissions again after a rebuild. With an Apple Development certificate (Xcode, Settings, Accounts, your Apple ID, Manage Certificates), sign with your team to keep them:

```bash
make install DEVELOPMENT_TEAM=XXXXXXXXXX
```

## CLI

| Command | Does |
|---|---|
| `tickler add <title> --at "YYYY-MM-DD HH:MM"` | Creates a reminder. `--notes <text>` or `--notes -` (stdin), `--link <url>` (repeatable), `--session <uuid>`, `--cwd <dir>`, `--json` |
| `tickler list` | Open reminders. `--due today` (default, overdue included), `week`, `overdue`, `all`; `--project <name>`; `--status done`; `--json` |
| `tickler show <id>` | One reminder with notes, links and session. `--json` |
| `tickler done <id>` | Marks it done |
| `tickler snooze <id> --for 1h` | Pushes it back from now: `15m`, `1h`, `2d`. Or `--to "YYYY-MM-DD HH:MM"` |
| `tickler edit <id>` | `--title`, `--at`, `--notes <text>` or `--notes -` |
| `tickler rm <id>` | Deletes it |
| `tickler resume <id>` | Focuses the WezTerm pane of the reminder's Claude session, or reopens it with `claude --resume` in the reminder's folder |
| `tickler import-apple --list Claude` | One-shot import of the open reminders of an Apple Reminders list, which is left untouched |

- `--session` defaults to `CLAUDE_CODE_SESSION_ID`, and `--cwd` to the current directory when a session is known.
- Dates on the CLI take only the strict local format `YYYY-MM-DD HH:MM`.
- Exit codes: `0` ok, `1` runtime error, `2` usage error, `3` unknown id.
- `TICKLER_DB=<path>` (or the hidden `--db <path>`) points everything at another database.

### JSON

`list --json` prints an array, the other commands one object:

```json
{
  "id": "r8wh83",
  "title": "OPS-2204: check le dashboard CTO",
  "notes": "Epic https://acme.atlassian.net/browse/OPS-2204",
  "due": "2026-10-01 11:00",
  "dueISO": "2026-10-01T11:00:00+02:00",
  "originalDue": "2026-10-01 11:00",
  "rescheduleCount": 0,
  "status": "open",
  "source": "claude",
  "sessionId": "5b26f281-1806-47aa-8842-0e264f7b9d35",
  "cwd": "/Users/you/src/platform-services",
  "project": "platform-services",
  "overdue": false,
  "links": [{ "kind": "jira", "label": "OPS-2204", "url": "https://acme.atlassian.net/browse/OPS-2204" }]
}
```

Link kinds: `gitlabMR`, `jira`, `grafana`, `slack`, `githubPR`, `other`.

## App

| Where | What |
|---|---|
| Menu bar | Count of today's reminders (overdue included); the glyph turns solid while one is overdue. The popover shows the next reminder with Resume, Snooze and Done, then overdue, today, tomorrow and later |
| Window | Views (Today, Next 7 Days, Overdue, All, Done), projects from the session folder, a 7-day strip to filter on a day, search, and a detail pane where title, date and notes edit in place |
| Notifications | One per reminder at its time, with Resume Session, Snooze 15 min, Snooze 1 hour, Tomorrow 09:30, Reschedule (type "jeudi 14h" or "in 3h"), Open Ticket, Open Slack Thread or Open Link, Mark Done. Reminders missed while the Mac slept are notified on wake, as one summary beyond three |
| Calendar | Every open reminder from 7 days ago to 60 days ahead becomes a 15 min event marked Free, without alert, with a `tickler://open/<id>` link |

Keyboard: `⌘N` new reminder, `⌘R` resume the session, `⌘↩` mark done, `⌘O` open the window from the popover.

The date fields accept French and English: `demain 9h30`, `lundi 10h`, `dans 2h`, `tomorrow 3pm`, `monday 10am`, `in 45 minutes`, `2026-10-06 10:00`.

### Settings

| Setting | Default |
|---|---|
| Calendar | None. Pick a writable calendar, for instance a "Claude" calendar created in Google Calendar with its default notifications set to none |
| WezTerm binary | Found automatically in `/opt/homebrew/bin`, `/usr/local/bin`, then the app bundle |
| Language | System, or force English or French (after a relaunch) |
| Open at login | Off |

For notifications to stay on screen until you act, set Tickler to **Alerts** in System Settings, Notifications.

## Development

| Command | Does |
|---|---|
| `make build` | Builds the package (core and CLI) |
| `make test` | Runs the Swift Testing suites |
| `make lint` | SwiftLint (strict) and SwiftFormat check |
| `make format` | Applies SwiftFormat |
| `make app` | Generates `Tickler.xcodeproj` with XcodeGen and builds the app |
| `make install` / `make uninstall` | Installs or removes the CLI and the app |

`lefthook install` sets up the pre-commit (format, lint, gitleaks, markdownlint, actionlint) and commit-msg (Conventional Commits) hooks. Debug builds write PNGs of their windows when started with `TICKLER_SNAPSHOT=<dir>`.

Layout: `Sources/TicklerCore` (model, store, date parsing, planners, session resume), `Sources/TicklerCLI`, `App/` (SwiftUI app), `project.yml` (XcodeGen), `assets/brand` (icon masters). Design notes live in `docs/superpowers`.

## License

MIT
