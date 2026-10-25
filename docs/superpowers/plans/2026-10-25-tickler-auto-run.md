# Auto-run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reminder with `autoRun` runs its resume message in its Claude session in the background when due, stores a human-readable result, and notifies with the verdict.

**Architecture:** Pure pieces in `TicklerCore` (mode, record, store API, argv builder, JSON/report parser, planner), one process runner in core, glue in the app (`AutoRunner`) wired into `AppModel.reconcileOnce`, then UI. The CLI only configures and displays; it never runs.

**Tech Stack:** Swift 6, SwiftPM, GRDB, Swift Testing, swift-argument-parser, SwiftUI, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-10-25-tickler-auto-run-design.md`

## Global Constraints

- macOS 14 target: `OSAllocatedUnfairLock`, no `Mutex`; collect task groups with `for await`.
- Every external process has a timeout and drained pipes. Auto-run timeout: 1800 s.
- Permission modes: `read` -> `dontAsk`, `write` -> `acceptEdits`, always `--permission-prompts none`. Never `bypassPermissions`.
- Arguments are argv, never interpolated into shell text.
- Text from Claude's result is display-only: never in `resumeMessage`, the SessionStart digest, or any prompt.
- SwiftLint strict (line 140, complexity 15), SwiftFormat; zero warnings; `make app` after any core type the app uses changes.
- App strings English + French in `App/Resources/Localizable.xcstrings`; CLI English only.
- Edit `skills/tickler/SKILL.md`, then `scripts/embed-skill.sh`; never edit `SkillContent.swift` by hand.
- Conventional Commits, one scope per commit, signed.

## Review Focus

- A reminder whose session the owner has open in a terminal at due time: `skipped` + plain notification, never a background run on that transcript (Task 4 test `skipsLiveTerminalSession`).
- Two reminders on one session due together: one starts, the other waits for the next pass (Task 4 test `oneRunPerSession`).
- App quit during a run: next launch turns the `running` row into `failed` "Interrupted" and does not start it again for the same due date (Task 1 test `interruptRunningMarksFailed`, Task 4 test `interruptedRunCountsForDueDate`).
- Claude answers without the report block, or in French around it: run succeeds, verdict `unknown`, headline is the first non-empty line (Task 2 tests `missingBlockFallsBackToFirstLine`, `verdictAmidFrenchText`).
- A resume message starting with `-` must not be read as a flag: argv puts `--` before it (Task 2 test `messageStartingWithDash`).

---

### Task 1: Data model and store

**Files:**
- Create: `Sources/TicklerCore/AutoRun/AutoRunMode.swift`, `Sources/TicklerCore/AutoRun/AutoRun.swift`
- Modify: `Sources/TicklerCore/Store/TicklerDatabase.swift` (migration after `v3-trigger`), `Sources/TicklerCore/Model/Reminder.swift` (`autoRun` column, `ReminderDraft.autoRun`), `Sources/TicklerCore/Store/ReminderStore.swift`
- Test: `Tests/TicklerCoreTests/AutoRunStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum AutoRunMode: String, Codable, Sendable, CaseIterable { case read, write }` with `var permissionMode: String` (`"dontAsk"` / `"acceptEdits"`).
  - `Reminder.autoRun: String? = nil` (column, `// swiftlint:disable:this implicit_optional_initialization` like `trigger`), `Reminder.autoRunMode: AutoRunMode?`, `ReminderDraft.autoRun: AutoRunMode?`.
  - `public struct AutoRun: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord`, table `"run"`, nested `enum State: String { running, succeeded, failed, cancelled, skipped }`, `enum Verdict: String { ok, watch, ko, unknown }`; fields `id, reminderId, forDueAt: Date, sessionId: String?, mode: AutoRunMode, startedAt: Date, endedAt: Date?, state, verdict: Verdict?, headline: String?, figures: [String]` (stored as JSON text), `nextStep, output, error: String?, denials: Int?, costUsd: Double?, durationMs: Int?`.
  - `public struct RunResult: Sendable, Equatable` with `state` (`.succeeded`/`.failed`/`.cancelled`), `verdict, headline, figures, nextStep, output, error, sessionId, denials, costUsd, durationMs`.
  - `ReminderStore`: `setAutoRun(_ id: String, _ mode: AutoRunMode?) throws -> Reminder` (throws `StoreError.autoRunNeedsPrompt` / `.autoRunNeedsFolder` when setting a mode without `resumePrompt` / `cwd`); `startRun(_ reminderId: String, at: Date) throws -> AutoRun?` (nil when a `running` row exists for that reminder; copies `dueAt`, `sessionId`, mode); `recordSkipped(_ reminderId: String, reason: String, at: Date) throws -> AutoRun`; `finishRun(_ runId: String, _ result: RunResult, at: Date) throws -> Bool` (only while `running`; stores the result's `sessionId` on the reminder when it had none); `runs(for id: String) throws -> [AutoRun]` newest first; `lastRuns(for ids: [String]) throws -> [String: AutoRun]`; `interruptRunning(at: Date) throws -> Int`.
  - Migration `v4-auto-run`: `reminder.autoRun` text; table `run` with FK `reminderId` -> `reminder.id` `onDelete: .cascade`, index on `reminderId`.

- [ ] **Step 1: Write failing tests** in `AutoRunStoreTests` using `ReminderStoreTests.store()` and `Fixture.now`: `migratesFromV3` (open a v3 db, `autoRun` nil, `run` exists); `setAutoRunNeedsPromptAndFolder`; `startRunRefusesSecond` (second `startRun` returns nil); `startRunCopiesDueAt` (`forDueAt == reminder.dueAt`); `finishRunOnlyWhileRunning` (second `finishRun` returns false); `finishRunAdoptsSessionId`; `interruptRunningMarksFailed` (state `.failed`, error `"Interrupted"`, `endedAt` set); `deleteCascadesRuns`; `lastRunsNewestFirst`.
- [ ] **Step 2:** `swift test --filter AutoRunStoreTests` -> fails to compile.
- [ ] **Step 3:** Implement the types, migration and store methods above. Store writes call `onChange()` like the others.
- [ ] **Step 4:** `swift test --filter AutoRunStoreTests` -> PASS; `make test` -> PASS.
- [ ] **Step 5:** `make app` (Reminder gained a field) -> builds with zero warnings.
- [ ] **Step 6:** Commit `feat(store): record auto-run mode and runs`.

### Task 2: Command line and result parser

**Files:**
- Create: `Sources/TicklerCore/AutoRun/AutoRunCommand.swift`, `Sources/TicklerCore/AutoRun/AutoRunParser.swift`, `Tests/TicklerCoreTests/Fixtures/claude-result-ok.json`, `claude-result-error.json`
- Modify: `Sources/TicklerCore/Resume/SessionResumer.swift` (extract the scrubbed list to `public static let scrubbedVariables: [String]`, `resumeCommand` uses it)
- Test: `Tests/TicklerCoreTests/AutoRunCommandTests.swift`, `AutoRunParserTests.swift`

**Interfaces:**
- Consumes: `Reminder`, `AutoRunMode`, `RunResult`, `AutoRun.Verdict` (Task 1).
- Produces:
  - `public enum AutoRunCommand { static let reportFormat: String; static func claudeArguments(prompt: String, sessionId: String?, mode: AutoRunMode) -> [String]; static func command(claudeArguments: [String]) -> [String] }`. `claudeArguments` = `["-p"] + (["--resume", id] if any) + ["--output-format", "json", "--permission-mode", mode.permissionMode, "--permission-prompts", "none", "--append-system-prompt", reportFormat, "--", prompt]`. `command` = `["env"] + scrubbed.flatMap { ["-u", $0] } + ["zsh", "-lic", #"exec claude "$@""#, "claude"] + claudeArguments`.
  - `reportFormat` exact text: `"End your answer with this block, in English, nothing after it:\nVerdict: OK | WATCH | KO - one sentence\nKey figures:\n- 3 to 5 lines, before -> after\nNext step: the next action, or none"`.
  - `public enum AutoRunParser { static func parse(stdout: Data, stderr: Data, status: Int32, timedOut: Bool, cancelled: Bool) -> RunResult; static func report(in text: String) -> (verdict: AutoRun.Verdict, headline: String?, figures: [String], nextStep: String?) }`.
  - Errors (exact English): `"Timed out after 30 min"`, `"claude exited with status \(status)"`, `"claude reported an error"`, `"Unreadable claude output"`, `"Stopped"` (cancelled). Failed runs keep the last 20 stderr lines appended after a newline.

- [ ] **Step 1: Fixtures.** `claude-result-ok.json`: the shape captured on 2026-10-25 from `claude -p --output-format json` (`type`, `subtype: "success"`, `is_error: false`, `result`, `session_id`, `total_cost_usd`, `duration_ms`, `num_turns`, `permission_denials: []`), with `result` holding a Markdown answer ending in a full report block; `claude-result-error.json`: `is_error: true`, `subtype: "error_max_turns"`, one entry in `permission_denials`.
- [ ] **Step 2: Failing tests.** Command: `readModeArgs` (contains `"--permission-mode", "dontAsk"`, `"--permission-prompts", "none"`, no `bypassPermissions`), `writeModeArgs` (`acceptEdits`), `noSessionDropsResume`, `messageStartingWithDash` (last two elements `"--", "-x"`), `commandScrubsSessionVars` (`-u CLAUDE_CODE_SESSION_ID` present, `exec claude "$@"` script, no prompt text inside the script element). Parser: `parsesSuccess` (verdict `.ok`, 3 figures, nextStep, cost, sessionId, denials 0), `parsesIsError` (state `.failed`, error `"claude reported an error"`, denials 1), `lowercaseVerdict` (`verdict: watch - x` -> `.watch`, headline `"x"`), `verdictAmidFrenchText`, `missingBlockFallsBackToFirstLine` (`.unknown`, headline = first non-empty line, state `.succeeded`), `nextStepNone` (`"none"` -> nil), `timeoutWins` (timedOut -> `.failed` `"Timed out after 30 min"`), `cancelled` (`.cancelled`, `"Stopped"`), `garbageStdout` (`"Unreadable claude output"`), `stderrTailKept` (25 lines in, last 20 out).
- [ ] **Step 3:** `swift test --filter 'AutoRunCommandTests|AutoRunParserTests'` -> FAIL.
- [ ] **Step 4:** Implement. Report parsing: scan lines from the last `Verdict:` line (case-insensitive prefix, optional leading `**`/`-`), verdict word before ` - ` or `:`, `Key figures:` collects following `- ` lines, `Next step:` rest of line.
- [ ] **Step 5:** Tests PASS, `swift test --filter SessionResumerTests` still PASS.
- [ ] **Step 6:** Commit `feat(auto-run): build the claude command and parse its result`.

### Task 3: Process runner

**Files:**
- Create: `Sources/TicklerCore/AutoRun/ClaudeRunProcess.swift`
- Test: `Tests/TicklerCoreTests/ClaudeRunProcessTests.swift`

**Interfaces:**
- Produces: `public final class ClaudeRunProcess: Sendable { init(command: [String], cwd: String, timeout: TimeInterval = 1800); func run() async -> ProcessResult; func cancel() }`, `public struct ProcessResult: Sendable { status: Int32; stdout: Data; stderr: Data; timedOut: Bool; cancelled: Bool }`. Launch failure (missing executable, missing cwd) returns `status: -1` with the error text in `stderr`.

- [ ] **Step 1: Failing tests** with `/bin/sh -c` commands (like `ProcessOutcomeTests`): `capturesBothStreams`, `runsInCwd` (`pwd` == temp dir), `timesOut` (`sleep 5`, timeout 0.5 -> `timedOut`), `cancelTerminates` (cancel after 0.2 s -> `cancelled`, returns under 2 s), `largeOutputDrained` (1 MB on stdout does not hang), `missingCwd`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implement on `Process` + two `Pipe`s drained by readers like `PipeReader` (move `PipeReader` to internal visibility and reuse it), the handle kept under `OSAllocatedUnfairLock`, `terminate()` then `SIGKILL` after 5 s if still alive. Bridge to async with `withCheckedContinuation` on a detached thread.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(auto-run): run claude with cwd, timeout and cancel`.

### Task 4: Planners

**Files:**
- Create: `Sources/TicklerCore/Planning/AutoRunPlanner.swift`
- Modify: `Sources/TicklerCore/Planning/NotificationPlanner.swift`
- Test: `Tests/TicklerCoreTests/AutoRunPlannerTests.swift`, `Tests/TicklerCoreTests/PlannerTests.swift`

**Interfaces:**
- Consumes: `Reminder.autoRunMode`, `AutoRun` (Task 1).
- Produces:
  - `public enum AutoRunDecision: Equatable, Sendable { case start(Reminder), skip(Reminder) }`
  - `public enum AutoRunPlanner { static func hasRun(_ reminder: Reminder, lastRun: AutoRun?) -> Bool; static func decide(reminders: [Reminder], lastRuns: [String: AutoRun], terminalSessions: Set<String>, autoRunSessions: Set<String>, now: Date) -> [AutoRunDecision]; static func nextDue(reminders: [Reminder], lastRuns: [String: AutoRun], now: Date) -> Date? }`
  - `hasRun`: `lastRun.state == .running || lastRun.forDueAt == reminder.dueAt`.
  - `decide`: open, `autoRunMode != nil`, not waiting, `dueAt <= now`, `!hasRun`; session in `autoRunSessions` -> omitted (waits); session in `terminalSessions` -> `.skip`; else `.start`, at most one per session in one pass (earliest `dueAt` first).
  - `NotificationPlanner.plan` and `catchUp` ignore reminders with `autoRun != nil`. `NotificationPlanner.runRequestId(reminderId:runId:) -> String` = `"\(reminderId)@run@\(runId)"`; `staleDelivered` keeps a `@run@` id while its reminder is open.

- [ ] **Step 1: Failing tests:** `startsWhenDue`, `notBeforeDue`, `notWhileWaitingForTrigger`, `onceForDueDate`, `rescheduledRunsAgain`, `interruptedRunCountsForDueDate` (failed run with same `forDueAt` -> nothing), `cancelledCountsForDueDate`, `skipsLiveTerminalSession`, `waitsForOwnRunOnSession`, `oneRunPerSession`, `noSessionStarts` (reminder with cwd but no session), `nextDueIgnoresRan`. In `PlannerTests`: `autoRunNotScheduled`, `autoRunNoCatchUp`, `runNotificationNotStale`, `runNotificationStaleWhenDone`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `make test` PASS.
- [ ] **Step 5:** Commit `feat(planning): decide auto-runs and keep them out of due notifications`.

### Task 5: CLI, README and skill

**Files:**
- Modify: `Sources/TicklerCLI/AddCommand.swift`, `Sources/TicklerCLI/MutationCommands.swift` (`EditCommand`), `Sources/TicklerCLI/ReminderPresentation.swift`, `Sources/TicklerCLI/ReminderCard.swift` (show), `README.md`, `skills/tickler/SKILL.md`, then `scripts/embed-skill.sh`
- Test: `Tests/TicklerCLITests/AutoRunCLITests.swift`

**Interfaces:**
- Consumes: `ReminderStore.setAutoRun`, `lastRuns`, `AutoRun` (Task 1).
- Produces: `add --auto-run <read|write>` (option, not a flag), `edit --auto-run <read|write|off>`; JSON keys `autoRun` (string|null) and `lastRun` (null or `{state, verdict, headline, figures, nextStep, denials, startedAt, endedAt}`); `show` prints `Last run: <state> <verdict> <date>` then headline, figures, next step.

- [ ] **Step 1: Failing tests:** `addAutoRunNeedsPrompt` (exit 2, message names `--prompt`), `addAutoRunNeedsFolder`, `addAutoRunRejectsUnknownMode` (exit 2 for `--auto-run maybe`), `addAutoRunWrite` (JSON `autoRun == "write"`), `editAutoRunOff`, `jsonLastRunNullWithoutRuns`, `jsonLastRunAfterFinish` (seed via store), `showPrintsLastRun`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `make test` PASS.
- [ ] **Step 5:** README: add `--auto-run` to the add/edit tables and the two JSON fields, one line saying runs happen in Tickler.app only. SKILL.md: the three Skill bullets from the spec. Run `scripts/embed-skill.sh`; `swift test --filter SkillVersionTests` PASS.
- [ ] **Step 6:** Commits `feat(cli): configure auto-run and show the last run`, `docs(readme): document auto-run`, `feat(skill): offer auto-run for read-only checks`.

### Task 6: AutoRunner in the app

**Files:**
- Create: `App/Sources/Services/AutoRunner.swift`
- Modify: `App/Sources/Model/AppModel.swift` (own `autoRunner`, `lastRuns: [String: AutoRun]` loaded in `reload()`, call `autoRunner.reconcile()` at the end of `reconcileOnce`, `interruptRunning` once at start, cancel on done/delete), `App/Sources/Services/NotificationService.swift` (post run notifications), `Sources/TicklerCore/Planning/NotificationPlanner.swift` (`NotificationCategory` gains `autoRunResult = "reminder.run.result"` and `autoRunFailed = "reminder.run.failed"`), the response handler for the new actions, `App/Sources/AppDelegate.swift` if categories are registered there.

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces (main actor): `final class AutoRunner { var running: [String: ClaudeRunProcess]` keyed by reminder id; `var runningSessions: Set<String>`; `func reconcile()`; `func start(_ reminder: Reminder)` (manual: Lancer maintenant / Relancer, bypasses `hasRun`, still one per session); `func stop(reminderId: String)` }.
- Behaviour: `reconcile` reads `AppModel.open`, `lastRuns`, terminal sessions = `SessionResumer.runningSessions(ids)` minus `runningSessions` (off the main actor), calls `AutoRunPlanner.decide`; `.skip` -> `recordSkipped(reason: "Session open in a terminal")` + failed-style notification; `.start` -> `startRun`, build `AutoRunCommand`, run `ClaudeRunProcess` in a `Task`, then `AutoRunParser.parse`, `finishRun`, `markNotified`, post notification, `reload()`, `reconcile()` again (a waiting same-session reminder may start). A one-shot `Timer` at `AutoRunPlanner.nextDue` triggers `reconcile`.
- Notification content: title `"<mark> <title>"` (✅ ok, 👀 watch, ❌ ko, ⚪ unknown, ⚠️ failed/skipped), body = headline or error first line; `userInfo["reminderId"]`; id `NotificationPlanner.runRequestId`. Actions: result -> "Voir le résultat" (open), "Terminé"; failed -> "Reprendre" (existing resume), "Relancer".

- [ ] **Step 1:** Implement; keep every `switch` over states in its own private helper (complexity 15).
- [ ] **Step 2:** `make lint && make test && make app` -> zero warnings.
- [ ] **Step 3:** Commit `feat(app): run due auto-run reminders in the background`.

### Task 7: App UI

**Files:**
- Create: `App/Sources/Views/AutoRunSection.swift` (result block, runs list, running row), `App/Sources/Views/AutoRunToggle.swift` (toggle + segmented mode)
- Modify: `App/Sources/Views/ReminderDetailView.swift`, `App/Sources/Views/QuickAddSheet.swift`, `App/Sources/Views/ReminderListView.swift`, `App/Sources/Views/MenuBarContent.swift`, `App/Sources/Views/Theme.swift` (verdict colours), `App/Resources/Localizable.xcstrings`

Follow the mockup (`.superpowers/brainstorm/88279-1792918775/content/auto-run.html`, screens 1, 2, 4, 5) and the spec's App section. Strings (FR): "Lancer automatiquement à l'échéance", "Lecture seule", "Peut modifier", "AUTO · lecture seule", "AUTO · peut modifier", "Lancer maintenant", "Reprendre dans le terminal", "En cours · %@", "Arrêter", "Résultat", "Chiffres clés", "Suite proposée", "Réponse complète", "%lld actions refusées", "Continuer dans le terminal", "Relancer", "Runs", "Session ouverte, lancement manuel". The full answer renders through `NotesView`'s Markdown path.

- [ ] **Step 1:** Implement the views; toggle disabled with a help text when the reminder has no resume prompt or folder.
- [ ] **Step 2:** `make lint && make app` zero warnings.
- [ ] **Step 3:** Commit `feat(app): show auto-run state and results`.

### Task 8: Manual check

- [ ] `make dev`. On a scratch reminder in this repo with a session id from a finished session, `--prompt "Run swift --version and report it"`, `--auto-run read`, due in 2 min: notification arrives with a verdict, result block shows, "Rouvrir" shows the run in the transcript.
- [ ] Same with `--prompt "Create a file /tmp/tickler-autorun-test"` in read mode: denied, result shows "1 actions refusées", file absent.
- [ ] Open the session in a terminal, make another reminder due: `skipped` notification.
- [ ] Start a run, quit the app, relaunch: run shows failed "Interrupted", no new run.
- [ ] Report results; no merge without the owner.
