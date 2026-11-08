# Work Schedule and Automatic Slotting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tickler places flexible reminders itself inside the owner's working hours, around their meetings and the other reminders, keeps them placed as the calendar changes, and tells the owner only when something needs them.

**Architecture:** Pure pieces in `TicklerCore` (schedule settings, working-time math, `SchedulePlanner`), store APIs for settings, busy intervals, placements and moves, and one `ScheduleRunner` shared by the CLI (after each write) and the app (inside `reconcileOnce`, after rewriting the busy copy from EventKit). The CLI never touches EventKit.

**Tech Stack:** Swift 6, SwiftPM, GRDB, Swift Testing, swift-argument-parser, SwiftUI, EventKit, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-11-07-tickler-auto-scheduling-design.md`

## Global Constraints

- Defaults: working days Mon to Fri, hours `09:30-19:30`, default duration 15 min, lunch off, no busy calendar.
- Freeze window 15 min; placement grid 5 min; horizon 30 working days; busy copy stale after 1 h (CLI places only the reminder it wrote), ignored after 24 h; app rewrites it when older than 15 min.
- Move reasons are fixed strings: `meeting`, `slot freed`, `day full`, `reminder added`, `settings changed`, `migration`.
- No calendar text (title, attendee, location, calendar name) is stored, printed, or sent to Claude: `busyInterval` holds start and end only.
- Planner moves never touch `rescheduleCount`; `reschedule` (edit `--at`, snooze, app "Plus tard") still bumps it.
- macOS 14 target: `OSAllocatedUnfairLock`, no `Mutex`; collect task groups with `for await`.
- SwiftLint strict (line 140, complexity 15), SwiftFormat; zero warnings; `make app` after any core type the app uses changes.
- App strings English + French in `App/Resources/Localizable.xcstrings`; CLI output English only.
- Edit `skills/tickler/SKILL.md`, then `scripts/embed-skill.sh`; never edit `SkillContent.swift` by hand.
- Conventional Commits, one scope per commit, signed (`git log --format="%h %G?"` shows `G`).
- Tests use the fixed clock: Thursday 2026-10-01 10:45, Europe/Paris (`Fixture`, `CLIHarness`).

## Review Focus

- A DST change day: 09:30 stays 09:30 wall-clock, the day's window is still 10 h (Task 3 test `dstDayKeepsWallClock`).
- A reminder longer than every gap of a day, or than the working day: the first goes to the next day, the second is refused by the CLI (Task 3 `longTaskSkipsToRoomyDay`, Task 5 `durationLongerThanWorkingDayRefused`).
- Settings with no working day, or end before start: `config set` refuses them; the planner never loops forever on bad stored data (Task 1 `parseRejectsEmptyDaysAndInvertedHours`, Task 3 `noWorkingDayLeavesRemindersUnplaced`).
- App closed for days: a 3-day-old busy copy is ignored by the CLI, which says so, and nothing but the new reminder moves (Task 4 `staleCopyOnlyPlacesTouched`, `ancientCopyIgnoresBusy`).
- A meeting spanning midnight or starting before working hours blocks only its overlap with the working window (Task 3 `busyClippedToWindow`).

---

### Task 1: Schedule settings

**Files:**
- Create: `Sources/TicklerCore/Schedule/WorkSchedule.swift`
- Modify: `Sources/TicklerCore/Store/TicklerDatabase.swift` (start migration `v6-schedule`: `setting` table only; Task 2 extends the same migration)
- Create: `Sources/TicklerCore/Store/ReminderStore+Settings.swift`
- Test: `Tests/TicklerCoreTests/WorkScheduleTests.swift`

**Interfaces:**
- Produces:
  - `public struct TimeOfDay: Codable, Hashable, Sendable, Comparable { public var minutes: Int; public init?(_ text: String); public var text: String }` (`"09:30"` <-> 570)
  - `public struct Lunch: Codable, Hashable, Sendable { public var minutes: Int; public var from: TimeOfDay; public var to: TimeOfDay }`
  - `public struct WorkSchedule: Codable, Hashable, Sendable { public var workingDays: Set<Int> /* Calendar weekday, 1 = Sunday */; public var start: TimeOfDay; public var end: TimeOfDay; public var defaultDurationMinutes: Int; public var lunch: Lunch?; public var busyCalendarIds: [String]; public static let standard: WorkSchedule }`
  - `extension WorkSchedule { static func parseDays(_:) -> Set<Int>?; static func parseHours(_:) -> (TimeOfDay, TimeOfDay)?; static func parseDuration(_:) -> Int? /* minutes, "15m" "1h" "90m", >0 */; static func parseLunch(_:) -> Lunch?? /* "off" -> .some(nil) */; var daysText: String; var hoursText: String; var workingMinutes: Int }`
  - `ReminderStore.schedule() throws -> WorkSchedule` (missing row = `.standard`), `ReminderStore.setSchedule(_:) throws`, `ReminderStore.busySnapshotAt() throws -> Date?`, `ReminderStore.setBusySnapshotAt(_:) throws` (internal, used by Task 2's `replaceBusy`).
- Table: `setting(key TEXT PRIMARY KEY, value TEXT NOT NULL)`, keys `workSchedule` (JSON) and `busySnapshotAt` (ISO 8601).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesDays() {
    #expect(WorkSchedule.parseDays("mon-fri") == [2, 3, 4, 5, 6])
    #expect(WorkSchedule.parseDays("mon,tue,thu") == [2, 3, 5])
    #expect(WorkSchedule.parseDays("sat-sun") == [7, 1])
}
@Test func parseRejectsEmptyDaysAndInvertedHours() {
    #expect(WorkSchedule.parseDays("") == nil)
    #expect(WorkSchedule.parseDays("mon-xyz") == nil)
    #expect(WorkSchedule.parseHours("19:30-09:30") == nil)
    #expect(WorkSchedule.parseHours("09:30-09:30") == nil)
    #expect(WorkSchedule.parseDuration("0m") == nil)
    #expect(WorkSchedule.parseDuration("2d") == nil)
}
@Test func parsesDurationAndLunch() {
    #expect(WorkSchedule.parseDuration("90m") == 90)
    #expect(WorkSchedule.parseDuration("1h") == 60)
    #expect(WorkSchedule.parseLunch("off") == .some(nil))
    #expect(WorkSchedule.parseLunch("45m@12:00-14:00") == Lunch(minutes: 45, from: TimeOfDay("12:00")!, to: TimeOfDay("14:00")!))
    #expect(WorkSchedule.parseLunch("3h@12:00-14:00") == nil) // longer than its window
}
@Test func storeDefaultsThenRoundTrips() throws {
    let store = try Fixture.store()
    #expect(try store.schedule() == .standard)
    #expect(WorkSchedule.standard.hoursText == "09:30-19:30")
    var edited = WorkSchedule.standard
    edited.defaultDurationMinutes = 30
    try store.setSchedule(edited)
    #expect(try store.schedule().defaultDurationMinutes == 30)
}
```

- [ ] **Step 2: Run `swift test --filter WorkScheduleTests`**: FAIL, `WorkSchedule` undefined.
- [ ] **Step 3: Implement the types, parsers and store methods.** `setSchedule` posts nothing itself; callers post the Darwin notification as for other writes.
- [ ] **Step 4: Run `swift test --filter WorkScheduleTests`**: PASS. `make lint` clean.
- [ ] **Step 5: Commit** `feat(core): work schedule settings shared by CLI and app`

### Task 2: Reminder scheduling fields, busy intervals, moves

**Files:**
- Modify: `Sources/TicklerCore/Model/Reminder.swift` (fields, draft, computed props)
- Modify: `Sources/TicklerCore/Store/TicklerDatabase.swift` (`v6-schedule`: columns, tables, data migration)
- Create: `Sources/TicklerCore/Schedule/ScheduleRecords.swift` (`BusyInterval`, `ScheduleMove`, `MoveReason`, `ScheduleConflict`)
- Modify: `Sources/TicklerCore/Store/ReminderStore.swift` (`add`, `reschedule`, new setters)
- Create: `Sources/TicklerCore/Store/ReminderStore+Schedule.swift`
- Test: `Tests/TicklerCoreTests/ScheduleStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 `setting` table and `setBusySnapshotAt`.
- Produces:
  - `Reminder`: `public var durationMinutes: Int = 15`, `public var fixed: Bool = false`, `public var notBefore: Date? = nil`, `public var deadline: Date? = nil`; `public var holdsItsTime: Bool { fixed || autoRun != nil || firedAt != nil }`; `public var earliestStart: Date { notBefore ?? dueAt }`; `public var isLate: Bool { deadline.map { dueAt > $0 } ?? false }`.
  - `ReminderDraft`: `durationMinutes: Int`, `fixed: Bool`, `notBefore: Date?`, `deadline: Date?` (init defaults 15, false, nil, nil).
  - `public enum MoveReason: String, Codable, Sendable { case meeting, slotFreed = "slot freed", dayFull = "day full", reminderAdded = "reminder added", settingsChanged = "settings changed", migration }`
  - `public struct ScheduleMove: Codable, Sendable, FetchableRecord, PersistableRecord { id: Int64?, reminderId, from: Date, to: Date, reason: MoveReason, at: Date, seen: Bool }`
  - `public struct Placement: Hashable, Sendable { public let reminderId: String; public let from: Date; public let to: Date }`
  - `ReminderStore.place(_ placements: [Placement], reason: (Placement) -> MoveReason, at: Date) throws -> [ScheduleMove]`: one transaction; skips a reminder whose `dueAt != from` or that is no longer open; sets `dueAt`, clears `notifiedAt`, never touches `rescheduleCount`; inserts one move per write.
  - `ReminderStore.replaceBusy(_ intervals: [DateInterval], at: Date) throws` (one transaction, sets `busySnapshotAt`), `ReminderStore.busy() throws -> [DateInterval]`
  - `ReminderStore.moves(since: Date, includeMigration: Bool = false) throws -> [ScheduleMove]`, `ReminderStore.markMovesSeen(reminderId:) throws`
  - `ReminderStore.setFixed(_ id: String, _ fixed: Bool) throws -> Reminder` (throws `StoreError.invalid` with message `"fixed by auto-run"` / `"fixed by its fired trigger"` when turning off a reminder whose `holdsItsTime` stays true), `setDuration(_ id: String, minutes: Int) throws -> Reminder`, `setDeadline(_ id: String, _ deadline: Date?) throws -> Reminder`.
  - `ReminderStore.reschedule(_:to:)` changed: a flexible reminder gets `notBefore = to` and `dueAt = to`; a fixed one only `dueAt`. Both bump `rescheduleCount` as today.
  - `ReminderStore.recordConflicts(_ conflicts: [ScheduleConflict], at: Date) throws -> [ScheduleConflict]`: returns only the ones never recorded (key: reminderId, start, end). `public struct ScheduleConflict: Hashable, Sendable { reminderId: String; interval: DateInterval }`.
- Tables: `busyInterval(start, end)`, `scheduleMove(...)`, `scheduleConflict(reminderId, start, end, at)`, primary key on the three first.
- Data migration (in `v6-schedule`, with `now = Date()` at migration time): open rows with `autoRun` or `firedAt` -> `fixed = 1`; other open rows with `dueAt > now` -> `notBefore` = 09:30 local of their `dueAt` day (the stored schedule does not exist yet, use `WorkSchedule.standard.start`). Moves made by the first planner run carry `migration`: Task 4 decides that from `ScheduleRunner`; this task only provides the reason.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func migrationMarksAutoRunFixedAndOthersFlexible() throws { /* build a v5 file through the migrator up to "v5-fresh", insert one autoRun row and one plain row due 2026-10-02 15:00, migrate; expect autoRun.fixed, plain.notBefore == Fixture.date("2026-10-02 09:30"), plain.durationMinutes == 15 */ }
@Test func placeSkipsChangedRowsAndKeepsRescheduleCount() throws {
    let store = try Fixture.store()
    let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
    let moves = try store.place([Placement(reminderId: r.id, from: Fixture.date("2026-10-01 13:00"), to: Fixture.date("2026-10-01 15:00"))],
                                reason: { _ in .meeting }, at: Fixture.now)
    #expect(moves.isEmpty)
    let ok = try store.place([Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))], reason: { _ in .meeting }, at: Fixture.now)
    #expect(ok.count == 1)
    #expect(try store.require(r.id).rescheduleCount == 0)
    #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-01 15:00"))
}
@Test func rescheduleSetsNotBeforeOnFlexibleOnly() throws { /* flexible: notBefore == new date, count 1; fixed: notBefore unchanged, count 1 */ }
@Test func cannotUnfixAutoRun() throws { /* setFixed(id, false) on an autoRun reminder throws */ }
@Test func replaceBusyStampsSnapshot() throws { /* replaceBusy([..], at: now); busy() equals input; busySnapshotAt() == now */ }
@Test func conflictsRecordedOnce() throws { /* same conflict twice -> second call returns [] */ }
```

- [ ] **Step 2: Run `swift test --filter ScheduleStoreTests`**: FAIL.
- [ ] **Step 3: Implement.** `add` copies the four draft fields. Columns: `durationMinutes INTEGER NOT NULL DEFAULT 15`, `fixed BOOLEAN NOT NULL DEFAULT 0`, `notBefore DATETIME`, `deadline DATETIME`.
- [ ] **Step 4: Run `make test`**: PASS (existing reschedule tests still pass). `make app` builds.
- [ ] **Step 5: Commit** `feat(core): scheduling fields, busy intervals and move log`

### Task 3: SchedulePlanner

**Files:**
- Create: `Sources/TicklerCore/Schedule/WorkingTime.swift`
- Create: `Sources/TicklerCore/Planning/SchedulePlanner.swift`
- Modify: `Sources/TicklerCore/Triggers/Trigger.swift` (`defaultDeadline` takes the schedule)
- Test: `Tests/TicklerCoreTests/SchedulePlannerTests.swift`, `Tests/TicklerCoreTests/TriggerTests.swift`

**Interfaces:**
- Consumes: `WorkSchedule`, `Reminder` fields, `Placement`, `ScheduleConflict`.
- Produces:
  - `public struct WorkingTime: Sendable { public init(schedule: WorkSchedule, calendar: Calendar); public func window(on day: Date) -> DateInterval?; public func nextWorkingStart(atOrAfter: Date) -> Date?; public func addingWorkingDays(_ n: Int, to: Date) -> Date? }` (`nil` when no working day exists within 14 calendar days of a step: the "no working day" guard).
  - `public enum PlanScope: Sendable, Equatable { case all, only(String) }`
  - `public struct SchedulePlan: Equatable, Sendable { public var placements: [Placement]; public var late: Set<String>; public var unplaced: Set<String>; public var conflicts: [ScheduleConflict] }`
  - `public enum SchedulePlanner { public static func plan(reminders: [Reminder], busy: [DateInterval], schedule: WorkSchedule, now: Date, calendar: Calendar, scope: PlanScope = .all, touched: String? = nil) -> SchedulePlan }`
  - `Trigger.defaultDeadline(after: Date, calendar: Calendar, schedule: WorkSchedule = .standard) -> Date`: 3 working days later at `schedule.start`.
- Algorithm (spec "The planner", steps 1 to 6), the parts the signature does not fix:
  - Input reminders: open ones only. Blocked = busy clipped to each day's window, every `holdsItsTime` reminder (`dueAt` for `durationMinutes`), every frozen one (flexible, `dueAt < now + 15 min`), and with `scope == .only(x)` every reminder other than `x` at its current `dueAt`.
  - Lunch: per working day before placing, the latest free gap of `lunch.minutes` inside `[lunch.from, lunch.to]` from busy and fixed only; none free -> no reservation.
  - Order: deadline ascending (nil last), then `createdAt`, then `id`.
  - Bound: `max(earliestStart, now)` for `touched`, `max(earliestStart, now + 15 min)` for the others; rounded up to the 5 min grid from midnight.
  - First fit inside one day's window; next working day otherwise; stop after 30 working days -> `unplaced`.
  - `late` when the start is after `deadline`. `conflicts`: each `holdsItsTime` reminder overlapping a busy interval, the interval as given (unclipped).
  - A placement is emitted only when the new start differs from `dueAt`.

- [ ] **Step 1: Write the failing tests** (schedule `.standard`, `now = Fixture.now` Thu 10:45 unless stated; helper `flex(_ title:, notBefore:, minutes: = 15, created:)`, `fixed(_:, at:, minutes:)`, `starts(plan, reminders) -> [String: String]` mapping title -> "HH:mm" or "EEE HH:mm" for another day)

```swift
@Test func packsBackToBack()            // 3 x 15m, notBefore now, touched none -> 11:00, 11:15, 11:30 (now + 15 min bound)
@Test func touchedStartsNow()           // touched reminder -> 10:45
@Test func avoidsBusy()                 // busy 11:00-11:30 -> 11:30, 11:45, 12:00
@Test func fixedBlocks()                // fixed 11:00 for 30m -> flexible at 11:30; fixed has no placement
@Test func respectsNotBefore()          // notBefore Mon 2026-10-05 08:00 -> "Mon 09:30"
@Test func overflowsToNextWorkingDay()  // now Fri 2026-10-02 19:20 -> "Mon 09:30"
@Test func longTaskSkipsToRoomyDay()    // 120m, busy every hour of Thu after 11:00 except 30m gaps -> "Fri 09:30"
@Test func frozenStays()                // flexible dueAt 10:55, earlier free -> no placement, and it blocks 10:55-11:10
@Test func pullsEarlierNotWithinFreeze()// flexible dueAt 15:00, notBefore 10:00 -> 11:00
@Test func neverBeforeNotBefore()       // notBefore 16:00 dueAt 17:00, free -> 16:00, not earlier
@Test func deadlineBeatsAge()           // old no-deadline, new deadline 12:00 -> new 11:00, old 11:15
@Test func olderKeepsPlace()            // old placed 11:00, new no deadline -> new 11:15, old unmoved
@Test func lateWhenNoRoomBeforeDeadline()// busy 11:00-19:30, deadline Thu 18:00 -> "Fri 09:30", late contains it
@Test func lunchReserved()              // lunch 45m@12:00-14:00, busy 13:30-14:00, 60m notBefore 12:00 -> 14:00
@Test func busyClippedToWindow()        // busy Wed 22:00 -> Thu 10:00 does not block Thu 11:00
@Test func dstDayKeepsWallClock()       // all 7 days, now 2026-10-25 08:00 -> 09:30 local, window length 600 min
@Test func noWorkingDayLeavesRemindersUnplaced() // workingDays [] -> unplaced, returns promptly
@Test func onlyScopeMovesNothingElse()  // .only(new): others stay even if earlier room exists
@Test func reportsFixedConflicts()      // fixed 14:00 30m, busy 14:15-15:00 -> one conflict
@Test func stableOnReplan()             // apply placements, plan again -> placements empty
```

Plus in `TriggerTests`: `defaultDeadlineFollowsSchedule` (working days Mon and Wed only, start 10:00, from Thu 2026-10-01: Mon 5, Wed 7, Mon 12 -> `Fixture.date("2026-10-12 10:00")`).

- [ ] **Step 2: Run `swift test --filter SchedulePlannerTests`**: FAIL.
- [ ] **Step 3: Implement** `WorkingTime`, then `SchedulePlanner`, one private helper per step to stay under complexity 15. Update the two `defaultDeadline` call sites to pass the stored schedule (CLI: `try store.schedule()`).
- [ ] **Step 4: Run `make test`**: PASS.
- [ ] **Step 5: Commit** `feat(core): schedule planner places flexible reminders`

### Task 4: ScheduleRunner

**Files:**
- Create: `Sources/TicklerCore/Schedule/ScheduleRunner.swift`
- Test: `Tests/TicklerCoreTests/ScheduleRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `public enum ScheduleCause: Sendable { case reminderAdded, settingsChanged, calendar, routine }`
  - `public struct ScheduleOutcome: Sendable { public var moves: [ScheduleMove]; public var late: Set<String>; public var unplaced: Set<String>; public var conflicts: [ScheduleConflict]; public var warning: String? }`
  - `public enum ScheduleRunner { public static func run(store: ReminderStore, now: Date, calendar: Calendar, cause: ScheduleCause, touched: String? = nil, freshBusy: Bool = false) throws -> ScheduleOutcome }`
- Rules:
  - Snapshot age from `busySnapshotAt`: `freshBusy` or < 1 h -> scope `.all`; 1 h to 24 h -> scope `.only(touched)` (no touched -> no writes), warning `"calendar copy is <N> h old, Tickler.app will correct the time"`; missing or > 24 h -> busy ignored, scope `.only(touched)`, warning `"no recent calendar copy, placed around other reminders only; Tickler.app will correct the time"`.
  - Reason per placement: on the first run with scope `.all` (setting key `scheduleMigrated` absent; set it in the same transaction as the writes) every move -> `migration`; otherwise `to < from` -> `slot freed`; different calendar day and later -> `day full`; else by cause: `reminderAdded` -> `reminder added`, `settingsChanged` -> `settings changed`, `calendar`/`routine` -> `meeting`. The touched reminder's own placement gets `reminder added` but is excluded from `moves` returned (it was not "moved").

- [ ] **Step 1: Write the failing tests**

```swift
@Test func freshCopyPlansEverything()        // snapshot now: an older flexible pulled earlier -> one move, reason slot freed
@Test func staleCopyOnlyPlacesTouched()      // snapshot 3 h old: touched placed, other untouched, warning starts "calendar copy is 3 h old"
@Test func ancientCopyIgnoresBusy()          // snapshot 3 days old, busy 10:45-12:00 -> touched at 10:45, warning "no recent calendar copy"
@Test func firstRunMovesAreMigration()       // first run: moves reason migration; second run: none
@Test func dayFullReason()                   // a meeting fills the rest of Thu -> move to Fri, reason day full
```

- [ ] **Step 2: Run `swift test --filter ScheduleRunnerTests`**: FAIL.
- [ ] **Step 3: Implement.** Read reminders with `store.list(.open)` (or the existing open filter), call the planner, `store.place`.
- [ ] **Step 4: Run `make test`**: PASS.
- [ ] **Step 5: Commit** `feat(core): schedule runner shared by CLI and app`

### Task 5: CLI flags on add, edit, snooze, done

**Files:**
- Modify: `Sources/TicklerCLI/AddCommand.swift`, `Sources/TicklerCLI/MutationCommands.swift`, `Sources/TicklerCLI/ReminderPresentation.swift` (JSON fields), `Sources/TicklerCLI/CLIContext.swift` (date-only parse)
- Create: `Sources/TicklerCLI/ScheduleReport.swift` (prints the outcome)
- Test: `Tests/TicklerCLITests/ScheduleCLITests.swift`

**Interfaces:**
- Consumes: `ScheduleRunner.run`, `WorkSchedule.parseDuration`, store setters.
- Produces: `func printSchedule(_ outcome: ScheduleOutcome, placed: Reminder?, asked: Date?, context: CLIContext, store: ReminderStore) throws`.
- Behavior:
  - `add`: `--at` optional (drop the "pass --at, --when, or both" check). No `--at`: `notBefore = now`. `--at "YYYY-MM-DD"`: `notBefore` = that day at `schedule.start`. `--fixed` requires `--at` (exit 2 `"--fixed needs --at"`), sets `dueAt` exactly. `--duration` default `schedule.defaultDurationMinutes`; refused above `schedule.workingMinutes` (`"--duration is longer than the working day (10h)"`). `--deadline` refused with `--fixed`. With `--when` and no `--at`: `notBefore = Trigger.defaultDeadline(...)`.
  - After the write, `ScheduleRunner.run(cause: .reminderAdded, touched: id)`, then post the change notification as today.
  - Output: the usual line, with the placed time; when the placed time differs from `--at` because it was outside working hours: `Placed Mon 5 Oct 09:30 (asked Sat 3 Oct 23:30, outside working hours)`; one line per move `Moved: <title> to Thu 1 Oct 11:30 (slot freed)`; the warning on stderr. JSON output gains `durationMinutes`, `fixed`, `notBefore`, `deadline`, `late`.
  - `edit`: `--duration`, `--fixed`/`--no-fixed` (exit 2 with the store's reason), `--deadline <date>|none`; `--at` goes through `reschedule` (Task 2). Runner with `.routine`, `touched: id`.
  - `snooze`, `done`: runner with `.routine`, `touched` = the id for snooze, nil for done.

- [ ] **Step 1: Write the failing tests** (`CLIHarness`, busy copy stamped `now` unless stated)

```swift
@Test func addWithoutAtTakesFirstSlot()            // "tickler add T" -> out contains "Thu 1 Oct 10:45" (or today's "10:45" format of ReminderTable)
@Test func addOutsideHoursSlides()                 // --at "2026-10-03 23:30" -> "Placed Mon 5 Oct 09:30 (asked Sat 3 Oct 23:30, outside working hours)"
@Test func fixedKeepsWeekendTime()                 // --at "2026-10-03 23:30" --fixed -> due 23:30 Sat, no "Placed" line
@Test func fixedNeedsAt()                          // exit 2, err contains "--fixed needs --at"
@Test func durationLongerThanWorkingDayRefused()   // --duration 12h -> exit 2
@Test func dateOnlyAtUsesWorkingStart()            // --at 2026-10-05 -> Mon 09:30
@Test func cannotUnfixAutoRunFromCLI()             // edit --no-fixed on auto-run -> exit 2 "fixed by auto-run"
@Test func staleCopyWarnsOnStderr()                // busySnapshotAt 3 h old -> err contains "calendar copy is 3 h old"
@Test func jsonCarriesScheduleFields()             // add --json -> durationMinutes 15, fixed false, late false
@Test func addPrintsOtherMoves()                   // existing reminder bumped by a --deadline add -> "Moved: ..."
```

- [ ] **Step 2: Run `swift test --filter ScheduleCLITests`**: FAIL.
- [ ] **Step 3: Implement.** Existing CLI tests that relied on `--at` being mandatory or on exact due echoes are updated in this task, not deleted.
- [ ] **Step 4: Run `make test`**: PASS.
- [ ] **Step 5: Commit** `feat(cli): duration, fixed and deadline flags with automatic placement`

### Task 6: `config`, `slot`, `plan` commands

**Files:**
- Create: `Sources/TicklerCLI/ConfigCommand.swift`, `Sources/TicklerCLI/SlotCommand.swift`, `Sources/TicklerCLI/PlanCommand.swift`
- Modify: `Sources/TicklerCLI/TicklerCommand.swift` (subcommands), `Sources/TicklerCLI/Completion.swift` if it lists commands
- Test: `Tests/TicklerCLITests/ScheduleCommandsTests.swift`

**Interfaces:**
- Consumes: Task 1 parsers and store, Task 3 planner, Task 4 runner (`cause: .settingsChanged` after `config set`).
- Behavior:
  - `tickler config [--json]`: `working-days mon-fri`, `working-hours 09:30-19:30`, `default-duration 15m`, `lunch off`, `busy-calendars <n> chosen in Tickler.app` (count only: names are calendar text). `config set <key> <value>` with keys `working-days`, `working-hours`, `default-duration`, `lunch`; `busy-calendars` refused with `"choose busy calendars in Tickler.app Settings"`; invalid value exit 2 with the expected format.
  - `tickler slot [--duration 15m] [--day YYYY-MM-DD] [--json]`: runs the planner on a synthetic draft (id `"slot"`, `touched`), prints `Thu 1 Oct 10:45-11:00`, writes nothing.
  - `tickler plan [YYYY-MM-DD] [--json]`: one line per block in time order: `11:00-11:30 busy`, `11:30-11:45 Review MR !412`, `11:45-12:00 Deploy check (fixed)`, `12:00-14:00 free`; late ones marked `(late)`. Titles through the existing `DisplaySafe` sanitizer.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func configShowsDefaults()            // out contains "working-hours 09:30-19:30" and "default-duration 15m"
@Test func configSetValidatesAndPersists()  // set working-days "" -> exit 2; set default-duration 30m -> config shows 30m
@Test func configRefusesBusyCalendars()     // exit 2
@Test func slotChangesNothing()             // slot --duration 30m -> "Thu 1 Oct 10:45-11:15"; list unchanged
@Test func slotOnDay()                      // --day 2026-10-05 -> "Mon 5 Oct 09:30-09:45"
@Test func planShowsBusyWithoutTitles()     // busy 11:00-11:30 stored -> line "11:00-11:30 busy", no other text on it
```

- [ ] **Step 2: Run `swift test --filter ScheduleCommandsTests`**: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test`**: PASS.
- [ ] **Step 5: Commit** `feat(cli): config, slot and plan commands`

### Task 7: SessionStart digest: moved and late

**Files:**
- Modify: `Sources/TicklerCore/Hook/SessionDigest.swift`
- Test: `Tests/TicklerCoreTests/SessionDigestTests.swift`

**Interfaces:**
- Consumes: `ReminderStore.moves(since:)`, `Reminder.isLate`.
- Behavior: a `Moved since yesterday:` section (moves with `at` after the start of the previous day, migration excluded, latest move per reminder), lines `- <title> moved to <when> (<reason>)` using the existing `title()` sanitizer and `when()` formatter; late reminders get ` (late)` on their existing line. Counts toward `maxLines`.

- [ ] **Step 1: Write the failing tests**: `listsMovesWithFixedReasons` (expects `- Review MR !412 moved to Fri 2 Oct 09:30 (day full)`), `migrationMovesHidden`, `lateMarked`, `movedLineNeverStartsWithSlashOrBang` (title `/clear` -> sanitized as today).
- [ ] **Step 2: Run `swift test --filter SessionDigestTests`**: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test`**: PASS.
- [ ] **Step 5: Commit** `feat(hook): report moved and late reminders in the session digest`

### Task 8: App engine: busy copy, replanning, conflicts, event length

**Files:**
- Modify: `App/Sources/Services/CalendarService.swift` (busy read, `fill` duration, `EKEventStoreChanged` observer)
- Modify: `App/Sources/Model/AppModel.swift` (`reconcileOnce`, time zone observer)
- Modify: `App/Sources/Services/NotificationService.swift` (conflict notification)

**Interfaces:**
- Consumes: `ScheduleRunner`, `ReminderStore.replaceBusy`, `recordConflicts`, `schedule().busyCalendarIds`.
- Produces: `CalendarService.busyIntervals(calendarIds: [String], from: Date, to: Date) -> [DateInterval]`; `NotificationService.notifyConflicts(_ conflicts: [ScheduleConflict], reminders: [String: Reminder]) async`.
- Behavior:
  - Busy filter: skip `isAllDay`, `availability == .free`, events with the `CalendarMarker` link, events where the current user's attendee status is `.declined`. Range: start of today to `WorkingTime.addingWorkingDays(30, to: now)`.
  - `reconcileOnce`: first, when calendar access is granted and (`busySnapshotAt` older than 15 min, or a `busyDirty` flag set by `EKEventStoreChanged`, wake, or launch), `replaceBusy`; without access, `replaceBusy([])` is NOT called (the CLI must see the copy as stale, not as "no meetings"). Then `ScheduleRunner.run(cause: dirty ? .calendar : .routine, freshBusy: wroteBusy)`, `reload()` when moves exist, `recordConflicts` -> `notifyConflicts` for new ones, then the existing notification, calendar and auto-run steps.
  - Conflict notification text: title `Conflict`, body `"<sanitized title> at 14:00 overlaps a meeting"`; no meeting data.
  - `NSSystemTimeZoneDidChange` and `NSCalendarDayChanged` -> `requestReconcile()`.
  - `fill`: `endDate = dueAt + durationMinutes * 60`. `CalendarPlanner.contentHash` includes `durationMinutes` (core change: add a test in `PlannerTests` `hashChangesWithDuration`).

- [ ] **Step 1: Write `hashChangesWithDuration` in `Tests/TicklerCoreTests/PlannerTests.swift`**, run it: FAIL.
- [ ] **Step 2: Update `CalendarPlanner.contentHash`**, run `swift test --filter PlannerTests`: PASS.
- [ ] **Step 3: Implement the app changes.**
- [ ] **Step 4: Run `make app`** with zero warnings, then `make dev`; with `TICKLER_DB` pointing at a scratch copy, add a meeting in a ticked calendar over a flexible reminder and check it moves within a minute, and that a fixed one notifies once.
- [ ] **Step 5: Commit** `feat(app): replan reminders around calendar busy times`

### Task 9: App UI: settings, editing, marks

**Files:**
- Modify: `App/Sources/Views/SettingsView.swift`, `App/Sources/Views/ReminderDetailView.swift`, `App/Sources/Views/QuickAddSheet.swift`, `App/Sources/Views/ReminderListView.swift`, `App/Sources/Model/AppModel.swift` (actions), `App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `store.schedule()/setSchedule`, `setFixed`, `setDuration`, `setDeadline`, `moves(since:)`, `markMovesSeen`, `Reminder.isLate`, `CalendarService.calendars`.
- Behavior:
  - Settings "Schedule" section: seven day toggles, start and end pickers (5 min steps, end after start), default duration stepper (5 to working-day length, step 5), lunch toggle with length and window, busy calendar checklist. Saving posts the change notification and calls `requestReconcile()`.
  - Detail pane: duration stepper, "Fixed time" toggle (disabled with the reason for auto-run or fired), deadline picker with a clear button; a flexible reminder's time is labeled "Placed" (French "Placé"); a "Moved from 14:00 (meeting)" line for an unseen move, marked seen when the detail opens.
  - Quick add: duration and "Fixed time"; a quick add without a time is flexible from now.
  - List: a small "moved" mark (unseen move from today or yesterday), "conflict" mark (a recorded conflict whose interval is still in the future), "late" mark. Each with a VoiceOver label.
  - Every new string in English with its French translation.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run `make app`**: zero warnings; `make lint` clean.
- [ ] **Step 3: `make dev`, check by hand**: change working hours in Settings, `tickler config` shows them; toggle Fixed on a reminder, `tickler show <id> --json` shows `fixed: true`.
- [ ] **Step 4: Commit** `feat(app): schedule settings and placement marks`

### Task 10: Skill and README

**Files:**
- Modify: `skills/tickler/SKILL.md`, `Sources/TicklerCore/Skill/SkillContent.swift` (generated), `README.md`

- [ ] **Step 1: Rewrite the Slotting and Repacking rules** as the spec's "Skill" section says: `--duration` when longer than the default, `--fixed` only when the time itself matters, a date-only `--at` for a named day, no `--at` for "as soon as possible"; `tickler plan <day>` to show a day; never compute slots by hand.
- [ ] **Step 2: Run `scripts/embed-skill.sh`**, then `swift test --filter SkillVersionTests`: PASS.
- [ ] **Step 3: README**: flags table (`--duration`, `--fixed`, `--no-fixed`, `--deadline`, date-only `--at`), commands table (`config`, `slot`, `plan`), JSON fields, the Settings "Schedule" section. Usage reference only.
- [ ] **Step 4: Run `make lint`** (markdownlint via prek on commit).
- [ ] **Step 5: Commit** `docs(skill): delegate slotting to tickler plan and slot` and, separately, `docs(readme): document scheduling flags and commands`
