# Tickler design: upcoming reminder near the notch

Date: 2026-10-13. Status: design agreed in conversation.

## Goal

When a reminder is about to be due, the owner sees it without opening the menu bar: a small black pill under the notch shows its title and a countdown ("12 min", then "now"). One click opens the reminder. The lead time is a setting, 5 minutes by default, and the feature is off until turned on.

## Scope

- `IslandPlanner` in `Sources/TicklerCore/Planning/`: a pure function deciding what the pill shows and when that next changes.
- `IslandController` and `IslandView` in the app: the panel, its placement and its timer.
- Two preferences and their rows in Settings, with French translations.
- README update (Settings section).

Out of scope: snooze and done on the pill, hover expansion, one pill per screen, animations beyond a fade, showing live status or notes.

## What the pill shows

`IslandPlanner.plan(open:now:lead:)` returns an `IslandPlan`:

```swift
public struct IslandPlan: Equatable, Sendable {
    public var shown: Reminder?      // nil: hide the pill
    public var othersInWindow: Int   // the "+N" badge, 0 hides it
    public var nextChange: Date?     // when to run the planner again
}
```

Rules:

- A reminder is a candidate when it is open, and not waiting on a trigger (`!isWaiting`: the trigger is cleared when it fires): a waiting reminder's due date is only its fallback deadline.
- A candidate is in the window when `now - 5 min <= dueAt <= now + lead`. Due within the last 5 minutes reads "now"; older overdue reminders are left to the notifications and the menu bar.
- `shown` is the candidate in the window with the earliest `dueAt`; ties are broken by id so the choice is stable.
- `othersInWindow` counts the other candidates in the window.
- `nextChange` is the earliest of: the `dueAt - lead` of the next candidate not yet in the window, and the `dueAt + 5 min` of every candidate in the window. `nil` when no candidate exists.

`lead` comes from the preference, clamped to 1...120 minutes.

## App side

- `IslandController` (main actor, owned by `AppModel`) runs the planner at the end of every `reload()` (the CLI Darwin notification, the minute tick, wake) and when a preference changes. It schedules one one-shot `Timer` at `nextChange`, replacing the previous one.
- The panel: a borderless, non-activating `NSPanel`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`, transparent background, no shadow. Leaving out `.fullScreenAuxiliary` keeps it off a full screen app's space (the notch area belongs to the app then).
- Placement on `NSScreen.main`: when `safeAreaInsets.top > 0` (a notch), 360 pt wide, centered and stuck to the top edge, its content under the notch height so it reads as an extension of the notch; otherwise centered horizontally, just under the menu bar (`visibleFrame.maxY`). Recomputed on `NSApplication.didChangeScreenParametersNotification`.
- `IslandView` (SwiftUI): clock icon, the title on one line truncated at the tail, the countdown, the `+N` badge. The countdown runs in a `TimelineView(.periodic(from:by: 1))` from `shown.dueAt`: "N min" rounded up, "now" from the due date on. The view never fetches anything; it renders the plan.
- Two icon buttons after the countdown: the logo of the first GitLab MR or GitHub PR link opens it, a terminal icon resumes the session (only with a `sessionId`). A click elsewhere opens the reminder. Every action dismisses the pill for it; the dismissal is in memory, keyed by id and due date, so a reschedule shows it again.
- Theme: black pill matching the notch in both appearances; the dot color of the reminder's `DueBucket` for the icon.

## Preferences

| Key | Type | Default | Settings row |
|---|---|---|---|
| `islandEnabled` | Bool | `false` | "Show the next reminder near the notch" |
| `islandLeadMinutes` | Int | `5` | "Show it before the reminder" (bordered number field with a "min" suffix, clamped to 1 to 120) |

Both in `Preferences`, both translated in `Localizable.xcstrings`.

## Edge cases

- A reminder rescheduled, snoozed, done or deleted from the CLI: the Darwin notification triggers `reload()`, so the pill updates within a second.
- A trigger fires (`ReminderStore.fire` makes it due now): it becomes a candidate due "now" and shows for 5 minutes.
- Sleep through the window: on wake, `reload()` reruns the planner; the pill shows only what is still in the window.
- Preference disabled: the panel is closed and the timer cancelled.

## Testing

- `IslandPlannerTests` (Swift Testing, `Fixture` clock): empty list; one reminder before, inside, at the edge of and after the window; due 4 and 6 minutes ago; a waiting trigger excluded, a fired one included; done excluded; earliest wins and ties by id; `othersInWindow`; `nextChange` for each case; `lead` clamping.
- App: `make app` compiles it; the panel placement and rendering are checked by hand with `make dev` on the built-in screen and an external one.
