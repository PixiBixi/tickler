# Tickler design: work schedule and automatic slotting

Date: 2026-11-07. Status: design agreed in conversation; the owner asked for the spec.

## Goal

Today Claude picks every reminder's time by hand, 30 minutes apart. A 15 minute task leaves a 15 minute hole, reminders land on meetings, and nothing stops one at 23:30 or on a Saturday. When a meeting moves, the reminders stay where they were.

The owner creates reminders so they never have to think about them again. Tickler takes over the timing: a reminder says how long it takes and from when, and Tickler places it in the owner's working hours, around their meetings and the other reminders, and keeps it placed as the calendar changes. The owner only hears about it when something needs them.

## Scope

- Work schedule settings, one store shared by the app (Settings pane) and the CLI (`tickler config`).
- Two kinds of reminders: fixed (keeps its time) and flexible (placed by Tickler).
- A pure `SchedulePlanner` in `TicklerCore`, run by the app on every change and by the CLI after each write.
- A copy of the owner's busy times in SQLite, written by the app (the only process with EventKit access), read by the CLI.
- `--duration`, `--fixed` on `add`/`edit`; `tickler slot`, `tickler plan`, `tickler config`.
- Moves shown in the app and in the SessionStart digest; a notification only when a fixed reminder collides with a meeting.
- The calendar event lasts the reminder's duration.
- Skill: drop the manual slotting and repacking rules, call the CLI instead.

## Non-goals

- Different hours per weekday, several schedules, time zone travel.
- Reading Google Calendar directly: EventKit only, through the app.
- Blocking the owner's time for colleagues: Tickler events stay "free".
- Reading back a Tickler event moved by hand in the calendar: the planner owns the time.
- Priorities beyond the deadline, task dependencies, splitting a long task over several slots.
- A fixed lunch block.

## Anti-goals

- A reminder's notification time changing in the last 15 minutes before it fires.
- Reminders oscillating between two slots from one run to the next.
- Any text read from the calendar (meeting titles, attendees, locations) reaching Claude, through the digest or a resume message.
- The CLI ever triggering a macOS calendar permission prompt.
- Moves counted as reschedules: `rescheduleCount` keeps meaning "the owner pushed it back" (`docs/ideas.md` builds on it).

## Settings

One `settings` table in the SQLite file (key, JSON value), read through `ReminderStore`, so the CLI works with the app closed and both see the same values. The app's `Preferences` (UserDefaults) keeps only app-only UI state.

| Setting | Default | CLI value |
|---|---|---|
| Working days | Mon to Fri | `mon-fri`, `mon,tue,thu` |
| Working hours | 09:30 to 19:30 | `09:30-19:30` |
| Default duration | 15 min | `15m`, `1h`, `90m` |
| Lunch | off | `off`, or `45m@12:00-14:00`: keep one free gap of that length inside that window, wherever it fits |
| Busy calendars | none | app only: the CLI cannot list calendars, `tickler config` prints the chosen names |

`tickler config` prints them, `tickler config set <key> <value>` changes one, `--json` for machines. A change posts the usual Darwin notification; the app replans.

## Reminder model

Migration `v6-schedule` adds to `reminders`:

- `durationMinutes` (Int, not null): set at creation from `--duration` or the default duration.
- `fixed` (Bool, not null, default false).
- `notBefore` (Date, nullable): earliest start of a flexible reminder.
- `deadline` (Date, nullable): latest acceptable start.

`dueAt` stays the single time every existing path reads (notifications, calendar, list, digest, catch-up). For a flexible reminder it is the planner's current placement.

A reminder is treated as fixed when any of these holds: `fixed` is set, it has auto-run, its trigger has fired (`firedAt` set), or it is frozen (see the planner). A reminder waiting on a trigger is flexible: its fallback deadline is its `notBefore`, the default stays "3 working days" and starts at the working hours' start.

### How the CLI maps onto it

- `add` with no `--at`: flexible, `notBefore` = now.
- `add --at "YYYY-MM-DD HH:MM"`: flexible, `notBefore` = that time. Out of working hours or on a non-working day it slides to the next working slot, and the CLI prints where it landed.
- `add --at "YYYY-MM-DD"` (new, date only): flexible, `notBefore` = that day's working start.
- `--fixed`: `dueAt` = `--at` exactly, even at night or on a weekend (this replaces the `--exact` flag of the first draft of the request). `--fixed` without `--at` is refused.
- `--deadline "YYYY-MM-DD[ HH:MM]"`: optional, flexible only.
- `--duration 15m|1h|90m` on `add` and `edit`: positive, at most the working day's length.
- `edit --fixed` / `edit --no-fixed`. `edit --at` sets `notBefore` (flexible) or `dueAt` (fixed). `--no-fixed` on a reminder fixed by auto-run or a fired trigger is refused (exit code 2, the message names the reason).
- `snooze --for 2h` / `--to <date>`: for a flexible reminder it sets `notBefore` and the planner places it; for a fixed one it moves `dueAt` as today. Both bump `rescheduleCount`, as today. A snooze past the deadline keeps the deadline: the reminder is placed and flagged `late`. The app's "Plus tard" goes through the same store method.

The JSON output gains `durationMinutes`, `fixed`, `notBefore`, `deadline`, and `late` (true when `dueAt` is past `deadline`).

### Migration of existing reminders

Open reminders with auto-run or a fired trigger become fixed. Every other open reminder becomes flexible with `durationMinutes` 15 and `notBefore` = the working start of its current `dueAt` day; the first planner run then places them. A reminder already due (`dueAt <= now`) is untouched. Done reminders are untouched. The first planner run after the migration reshuffles every open flexible reminder at once; those moves get the reason `migration` and are not shown in the app or the digest.

Column defaults (`durationMinutes` 15, `fixed` false, `notBefore` null) keep an older CLI working on a migrated file: a row it inserts is a flexible reminder whose `notBefore` falls back to its `dueAt`. A newer file opened by an older binary follows whatever the existing migrations already do; no new version guard.

## Busy times

The app writes a `busy_intervals` table (start, end) and a `busy_snapshot_at` setting:

- Events from the calendars ticked in Settings, from the start of today to the planner's horizon.
- Skipped: all-day events, events the owner declined, events carrying the Tickler marker (`CalendarMarker`), events whose availability is "free".
- Rewritten in one transaction on launch, on wake, on `EKEventStoreChanged`, and on the minute tick when older than 15 minutes.
- Only start and end are stored: no title, no calendar name. This is what keeps calendar text away from Claude.

The CLI plans with that table. When `busy_snapshot_at` is missing or older than 1 hour, it still places (only the reminder it wrote, see "Who runs it") and prints one warning line ("calendar copy is 3 h old, Tickler.app will correct the time"). Past 24 hours, it ignores the busy intervals and places around the other reminders only, saying so: a days-old copy is worse than none. The app replans with fresh data at its next run.

## The planner

`SchedulePlanner.plan(reminders:busy:settings:now:calendar:) -> SchedulePlan`, pure, in `Sources/TicklerCore/Planning/`, tested with the `Fixture` clock like the other planners.

Inputs: open reminders, busy intervals, settings, now. Output: a new `dueAt` per flexible reminder whose placement changes, a `late` flag per reminder, and the list of fixed reminders that overlap a busy interval.

1. Blocked time: busy intervals, every fixed reminder (`dueAt` for `durationMinutes`), every frozen reminder, outside working hours, non-working days. With lunch on, the lunch gap is reserved per day before any flexible reminder is placed: the latest free gap of the lunch length inside the window, computed from busy intervals and fixed reminders only (my call: morning tasks pack first). A lunch gap that shifts because a meeting moved gives its reminders the reason `meeting`.
2. Frozen: a flexible reminder whose current `dueAt` is in less than 15 minutes, or already due, keeps its time and counts as blocked. A move never lands a reminder less than 15 minutes from now either: placement starts at `max(notBefore, now + 15 min)` for a reminder that already had a placement, `max(notBefore, now)` for a new one.
3. Order: flexible reminders sorted by deadline (earliest first, none last), then `createdAt`. A deadline always wins over age; among reminders with no deadline, or the same one, older reminders keep their place over new ones, so a new reminder fills a gap instead of pushing older ones back. A `late` reminder keeps its deadline rank.
4. Each takes the earliest free interval of its duration starting at the bound of step 2, inside one working day. A day with no room sends it to the next working day. Placement is on a 5 minute grid.
5. If it cannot start before its deadline, it still takes the first free slot after it and is flagged `late`.
6. Horizon: 30 working days from now; a reminder that does not fit by then keeps its `notBefore` time and is flagged in the app (my call; not expected in practice).

Because each run rebuilds the placement from `notBefore` with a stable order, reminders move earlier on their own when a meeting is cancelled or a reminder is done early, and never earlier than their `notBefore`: a reminder aimed at Monday stays on Monday, one aimed at "as soon as possible" that overflowed to tomorrow comes back today when room appears. Same inputs, same output: no oscillation.

Time: working hours, days, the grid and the horizon are wall-clock in the Mac's current time zone, computed through `Calendar` (DST included). The app replans on `NSSystemTimeZoneDidChange`.

### Who runs it

- The app, inside `AppModel.requestReconcile`, before the notification and calendar planners, on every change it already reacts to (Darwin notification, minute tick, wake) plus a busy-times rewrite. Placements are written in one transaction through a new `ReminderStore.place(_:)` that takes the `dueAt` each placement was computed from and skips any reminder changed since (the "conditional write filters on the data it read" rule, as `fire` does). It never touches `rescheduleCount`.
- The CLI, at the end of `add`, `edit`, `snooze`, `done` and `config set`, with the same store method, then posts the Darwin notification. It prints the new reminder's time, and one line per other reminder it moved.
- The app has the last word. With a busy copy under 1 hour old, the CLI writes the whole plan: both processes then compute from the same data and the app's run is a no-op. With an older copy (app closed), the CLI places only the reminder it just wrote and moves nothing else, so a stale copy never reshuffles the day; the app replans everything with fresh data at its next run.

The notification request id already contains `dueEpoch`, so a placement change replaces the pending notification; the calendar hash changes with `dueAt` and duration, so the event follows.

## Telling the owner

- Every placement change of a flexible reminder is recorded in a `schedule_moves` table (reminder id, from, to, reason, at, seen). Reason is a fixed string chosen by the planner: `meeting`, `slot freed`, `day full`, `reminder added`, `settings changed`.
- App: a "moved" mark on the reminder in the list and the old time in the detail pane, cleared once the reminder is opened or after the day passes. No notification.
- SessionStart digest: a "Moved since yesterday" section, one line per reminder (`Review MR !412 moved to Mon 9 14:30 (meeting)`), built only from sanitized titles, fixed reason strings and dates.
- A fixed reminder overlapping a busy interval: one macOS notification per (reminder, interval), plus a conflict mark in the app until it is resolved. The text names the reminder and the time only ("Conflict: Deploy check at 14:00 overlaps a meeting"), never the meeting.
- `late` reminders: a mark in the app and in the digest, no notification.

## Triggers

A fired trigger keeps today's behavior: the reminder becomes due now, fixed, and notifies immediately, even during a meeting. The `--when` default deadline uses the working days and the working start from the settings instead of weekdays and 09:30.

## Commands

| Command | Does |
|---|---|
| `tickler slot [--duration 15m] [--day YYYY-MM-DD]` | Prints where a new reminder would go (default duration, from now or from that day's start), changes nothing |
| `tickler plan [YYYY-MM-DD]` | Prints the day: busy blocks (as "busy", no titles), reminders with their times and durations, fixed ones marked, free gaps |
| `tickler config`, `tickler config set <key> <value>` | Shows or changes the schedule settings |

The `repack` command from the request is not built: repacking is what the planner does on every run.

## App

- Settings: a "Schedule" section with working day toggles, working hours, default duration, lunch, and the busy calendar checklist (calendars from `CalendarService.loadCalendars`).
- Quick add and detail pane: duration, a "Fixed time" toggle, the deadline. For a flexible reminder the time shown is the placement, labeled as such.
- Calendar events last `durationMinutes` (`CalendarService.fill`, today hard-coded to 15 minutes).
- English strings with French translations in `Localizable.xcstrings`.

## Skill

Once shipped: the Slotting and Repacking rules in `skills/tickler/SKILL.md` shrink to "pass `--duration` when a task is longer than the default, `--fixed` only when the time itself matters (a meeting, a deploy window, the owner said 'à 14h pile'), a date-only `--at` for 'lundi', nothing for 'dès que possible'". Then `scripts/embed-skill.sh`, README tables for the new flags and commands.

## Left to the builder

- Table and column names, the exact `SchedulePlan` shape, how `place` batches its writes.
- How the "moved" and conflict marks look in the list.
- Whether `plan` and `slot` share a renderer with `ReminderTable`.
