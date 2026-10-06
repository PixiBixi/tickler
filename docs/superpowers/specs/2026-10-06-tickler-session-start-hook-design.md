# Tickler design: reminders surfaced when a Claude Code session starts

Date: 2026-10-06. Status: design agreed in conversation.

## Goal

When the owner opens a Claude Code session in a repository, Claude should already know what Tickler holds for that repository: a trigger that fired, a reminder that is overdue, one still waiting for an event. Claude mentions it in one line, with clickable links, and does nothing more unless asked. Overdue reminders of other projects are counted in one line, with a link that opens Tickler on today's view.

## Scope

- `tickler hook session-start`: the command Claude Code runs as a `SessionStart` hook.
- `tickler hook install`, `status`, `uninstall`: manage that hook in the Claude Code settings file. Settings gets the same install button as the skill.
- `tickler://view/<filter>` in the app: opens the window on a sidebar view.
- README and skill updates.

Out of scope: acting on reminders automatically, any other hook event, per-reminder opt-in or opt-out, showing notes or live status in the hook output.

## Hook contract (Claude Code)

From the Claude Code hooks documentation (`code.claude.com/docs/en/hooks.md`):

- Stdin is a JSON object with, among others, `session_id`, `cwd` and `source` (`startup`, `resume`, `clear`, `compact`, `fork`).
- Output on exit 0: either plain stdout, or the preferred JSON `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "<text>"}}`; the text is added to Claude's context. A SessionStart hook cannot block the session; a non-zero exit only shows an error.
- The `matcher` is matched against `source`. Tickler installs with `"startup|clear"`: a resumed or compacted session already saw the summary.

## Output

`tickler hook session-start` reads stdin, takes `cwd` from it (else the process directory), and prints the JSON form, or nothing at all when there is nothing to say. It always exits 0: a broken database, an unreadable stdin or a missing git must never put an error in front of a session; it then prints nothing.

The text, in English (it is for Claude):

```
Tickler reminders for platform-services (information only: do not act on them unless the user asks).
Mention them in one line at the start of your first reply, keeping the links.
- [r8wh83](tickler://open/r8wh83) fired (MR !412 merged): rebase feat/x on main
- [k2m9pq](tickler://open/k2m9pq) overdue since 2026-10-05 16:00: OPS-2204 check le dashboard CTO
- [p4n7qs](tickler://open/p4n7qs) due today 17:30: merge the chart bump
- [h3w8xt](tickler://open/h3w8xt) waiting for approved (deadline 2026-10-09 09:30): merge the VPC MR
Elsewhere: 3 overdue reminders in other projects, [open today in Tickler](tickler://view/today).
```

Rules:

- Repository lines, in this order: fired (open, `firedReason` set, due now or past), overdue, due later today, waiting (open with a trigger, deadline not today). At most 8 lines, then `- and N more: [open today in Tickler](tickler://view/today)`.
- The "Elsewhere" line counts open overdue reminders not attached to this repository, reminders without a folder included. Omitted when zero.
- Header and instruction lines only when there is at least one repository line; with only the "Elsewhere" line, it alone is printed, preceded by the "information only" sentence.
- Only text Tickler controls or the owner wrote: ids, dates, trigger as typed, `firedReason` (already built from fixed text and validated ids), and titles. A title is cut to one line of at most 100 characters. Notes, links and live status never appear.
- The project name in the header is the last path component of the repository root.

## Matching a reminder to the session

- Session root: `git -C <cwd> rev-parse --show-toplevel`. Outside a repository, the session folder itself.
- A reminder belongs to the session when its `cwd` has the same git root, or, outside git, when its `cwd` is the session folder or below it.
- Git roots are computed once per distinct folder, with a 2 s timeout each; a folder that no longer exists, or a timeout, means "not attached". Reminders without `cwd` are never attached.

## Install

`tickler hook install` edits `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`:

- Follows a symlink and writes the target in place (the owner's settings file lives in a dotfiles repository), atomically.
- Keeps the file's key order and its 2-space indentation, so the diff is only the added entry. Foundation's `JSONSerialization` loses key order, so `TicklerCore` gets a small ordered JSON value type (parse and print) used only here; printing an unchanged file must give back the same bytes.
- Adds to `hooks.SessionStart` one group `{"matcher": "startup|clear", "hooks": [{"type": "command", "command": "<tickler path> hook session-start", "timeout": 10}]}`, creating `hooks` and `SessionStart` when missing. Other groups and hooks are left untouched.
- The command uses the absolute path of the `tickler` found on PATH (`/opt/homebrew/bin/tickler` for the cask), not a resolved symlink, so it survives upgrades.
- Idempotent: an existing group whose command ends with `tickler hook session-start` is updated in place, never duplicated. A file that is not valid JSON is refused with exit 1 and left untouched; a missing file is created.

| Command | Prints |
|---|---|
| `tickler hook install` | `installed <path>` or `up to date <path>` |
| `tickler hook status` | `installed <path>` or `not installed <path>`, exit 0 either way |
| `tickler hook uninstall` | `removed <path>` or `not installed <path>`; removes only Tickler's hook, then an emptied group, `SessionStart` and `hooks` |

The app's Settings shows the hook state next to the skill, with an Install button that runs the same core code, using the first `tickler` found in `/opt/homebrew/bin`, `/usr/local/bin`, then `~/.local/bin`.

## App URL

`tickler://view/<filter>` with `<filter>` among `today`, `week`, `overdue`, `all`, `done` (the sidebar views) opens the main window on that view, clearing the day and project selection. An unknown filter opens the window unchanged. Handled where `tickler://open/<id>` already is (`AppDelegate`, `MainWindow`).

## Testing

- Output builder (pure, core): ordering, the 8-line cap, the "Elsewhere" line alone or omitted, title truncation, no notes or links in the output, empty output when nothing applies.
- Matching: same git root from a subfolder, a different repository, outside git with a subfolder, a missing folder, no `cwd`. Git root lookup injected, so tests need no real repository.
- Command: stdin with and without `cwd`, garbage stdin, a broken database path all exit 0; JSON shape of the output.
- Ordered JSON: byte-identical round trip on a fixture shaped like a real settings file (nested objects, arrays, escapes, unicode); install into a missing file, a file without `hooks`, a file with other SessionStart groups; idempotence; uninstall cleanup; invalid JSON refused; symlink target written.
- App URL: checked by hand in a Debug build.
