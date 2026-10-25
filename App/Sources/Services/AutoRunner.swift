import Foundation
import os
import TicklerCore

private let log = Logger(subsystem: "io.github.pixibixi.tickler", category: "auto-run")

/// Runs due auto-run reminders in their Claude session in the background, one run at a time per session,
/// stores the result and notifies with the verdict.
@MainActor
@Observable
final class AutoRunner {
    /// Stored as the reason of a skipped run; the notification shows its own localized text.
    static let skippedReason = "Session open in a terminal"

    /// Keyed by reminder id.
    private(set) var running: [String: ClaudeRunProcess] = [:]
    /// Sessions our own `claude -p --resume` children hold, or the reminder id for a run that starts a new session.
    private(set) var runningSessions: Set<String> = []

    @ObservationIgnored private var sessionKeys: [String: String] = [:]
    @ObservationIgnored private var startTimes: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false

    private var model: AppModel {
        AppModel.shared
    }

    func isRunning(reminderId: String) -> Bool {
        running[reminderId] != nil
    }

    func startedAt(reminderId: String) -> Date? {
        startTimes[reminderId]
    }

    // MARK: Planning

    /// One pass at a time: two overlapping passes would record the same skip twice.
    func reconcile() {
        guard !reconciling else {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                reconcileAgain = false
                await reconcileOnce()
            } while reconcileAgain
            reconciling = false
        }
    }

    private func reconcileOnce() async {
        guard model.store != nil else { return }
        // The process table is only walked when a run is due.
        guard !decisions(terminalSessions: []).isEmpty else {
            armTimer()
            return
        }
        let ids = Set(model.open.filter { $0.autoRunMode != nil }.compactMap(\.sessionId))
        // A run that ended during the scan was still in the process table: its session is ours, not a terminal's.
        let ownBefore = runningSessions
        let live = await Self.liveSessions(ids)
        let terminal = live.subtracting(ownBefore).subtracting(runningSessions)
        let decided = decisions(terminalSessions: terminal)
        for decision in decided {
            apply(decision)
        }
        if !decided.isEmpty {
            model.reload()
        }
        armTimer()
    }

    private func decisions(terminalSessions: Set<String>) -> [AutoRunDecision] {
        AutoRunPlanner.decide(
            reminders: model.open,
            lastRuns: model.lastRuns,
            terminalSessions: terminalSessions,
            autoRunSessions: runningSessions,
            now: Date()
        ).filter { running[reminder(of: $0).id] == nil }
    }

    private func reminder(of decision: AutoRunDecision) -> Reminder {
        switch decision {
        case let .start(reminder), let .skip(reminder): reminder
        }
    }

    private func apply(_ decision: AutoRunDecision) {
        switch decision {
        case let .start(reminder): launch(reminder)
        case let .skip(reminder): skip(reminder)
        }
    }

    /// One-shot, at the next due date that still has a run to start; every pass re-arms it.
    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard let next = AutoRunPlanner.nextDue(reminders: model.open, lastRuns: model.lastRuns, now: Date()) else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { _ in
            Task { @MainActor in AppModel.shared.autoRunner.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Off the main actor: it walks the process table.
    private nonisolated static func liveSessions(_ ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await Task.detached {
            SessionResumer(driver: WezTermDriver(binary: URL(fileURLWithPath: "/usr/bin/false"))).runningSessions(ids)
        }.value
    }

    // MARK: Manual start and stop

    /// "Run now" and "Run again": bypasses the once-per-due-date rule, never a session in use.
    func start(_ reminder: Reminder) {
        guard reminder.status == .open, reminder.autoRunMode != nil, running[reminder.id] == nil else { return }
        if let session = reminder.sessionId, runningSessions.contains(session) {
            model.showError(String(localized: "A background run is already using this session"))
            return
        }
        Task { [weak self] in
            let live = await Self.liveSessions(Set([reminder.sessionId].compactMap(\.self)))
            guard let self else { return }
            if let session = reminder.sessionId, live.contains(session), !runningSessions.contains(session) {
                model.showError(String(localized: "The session is open in a terminal: continue there"))
                return
            }
            launch(reminder)
            model.reload()
        }
    }

    /// The run ends `cancelled` once the process exits; `finish` then clears it.
    func stop(reminderId: String) {
        running[reminderId]?.cancel()
    }

    // MARK: Running

    /// Reads the reminder again: the snapshot the decision was made on may be out of date.
    private func launch(_ decided: Reminder) {
        guard let store = model.store, running[decided.id] == nil,
              let reminder = try? store.get(decided.id), reminder.status == .open, reminder.autoRunMode != nil
        else { return }
        let key = reminder.sessionId ?? reminder.id
        guard !runningSessions.contains(key), let run = try? store.startRun(reminder.id, at: Date()) else { return }
        guard let cwd = reminder.cwd, !cwd.isEmpty, let prompt = reminder.resumeMessage, !prompt.isEmpty else {
            finish(run, reminder: reminder, result: RunResult(state: .failed, error: "No folder or resume prompt to run"))
            return
        }
        let arguments = AutoRunCommand.claudeArguments(prompt: prompt, sessionId: run.sessionId, mode: run.mode)
        let process = ClaudeRunProcess(command: AutoRunCommand.command(claudeArguments: arguments), cwd: cwd)
        running[reminder.id] = process
        sessionKeys[reminder.id] = key
        startTimes[reminder.id] = run.startedAt
        runningSessions = Set(sessionKeys.values)
        Task { [weak self] in
            let output = await process.run()
            let result = AutoRunParser.parse(
                stdout: output.stdout,
                stderr: output.stderr,
                status: output.status,
                timedOut: output.timedOut,
                cancelled: output.cancelled
            )
            self?.finish(run, reminder: reminder, result: result)
        }
    }

    /// Every way a run ends comes through here, so `running` and `runningSessions` are always cleared.
    private func finish(_ run: AutoRun, reminder: Reminder, result: RunResult) {
        running[reminder.id] = nil
        sessionKeys[reminder.id] = nil
        startTimes[reminder.id] = nil
        runningSessions = Set(sessionKeys.values)
        guard let store = model.store else { return }
        if write("finish the run", { try store.finishRun(run.id, result, at: Date()) }) == true {
            // The reminder as it was when the run started: a reschedule meanwhile keeps its own notification.
            var asRun = reminder
            asRun.dueAt = run.forDueAt
            write("mark the reminder notified") { try store.markNotified([asRun], at: Date()) }
            if result.state != .cancelled {
                let notice = Self.notice(for: result)
                Task { await model.notifications.postRun(reminder: reminder, runId: run.id, notice: notice) }
            }
        }
        model.reload()
        // A reminder of the same session may be waiting for this run to end.
        reconcile()
    }

    /// Runs a store write and logs its failure instead of dropping it.
    @discardableResult
    private func write<T>(_ what: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            log.error("Could not \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func skip(_ reminder: Reminder) {
        guard let store = model.store,
              let run = write("record the skipped run", { try store.recordSkipped(reminder.id, reason: Self.skippedReason, at: Date()) })
        else { return }
        write("mark the reminder notified") { try store.markNotified([reminder], at: Date()) }
        let notice = RunNotice(
            mark: "⚠️",
            body: String(localized: "Session open, start it manually"),
            failed: true
        )
        Task { await model.notifications.postRun(reminder: reminder, runId: run.id, notice: notice) }
    }

    // MARK: Notification content

    /// Run text from Claude only reaches the notification body, never a prompt.
    private static func notice(for result: RunResult) -> RunNotice {
        switch result.state {
        case .succeeded:
            RunNotice(mark: mark(for: result.verdict ?? .unknown), body: firstLine(result.headline), failed: false)
        case .failed, .cancelled:
            RunNotice(mark: "⚠️", body: firstLine(result.error), failed: true)
        }
    }

    private static func mark(for verdict: AutoRun.Verdict) -> String {
        switch verdict {
        case .ok: "✅"
        case .watch: "👀"
        case .ko: "❌"
        case .unknown: "⚪"
        }
    }

    private static func firstLine(_ text: String?) -> String {
        text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// What a run's notification says: the verdict mark, one line, and which action set it gets.
struct RunNotice {
    let mark: String
    let body: String
    let failed: Bool
}
