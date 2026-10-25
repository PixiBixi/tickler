import Foundation
import Testing
@testable import TicklerCore

private func autoReminder(
    _ id: String, at due: String = "2026-10-01 10:00", session: String? = "s-\(UUID().uuidString)", mode: String? = "read",
    trigger: String? = nil, status: Reminder.Status = .open
) -> Reminder {
    let date = Fixture.date(due)
    var reminder = Reminder(
        id: id, title: "t", notes: "", dueAt: date, originalDueAt: date, rescheduleCount: 0, status: status,
        sessionId: session, cwd: "/tmp", source: .claude, externalRef: nil, notifiedAt: nil,
        doneAt: nil, createdAt: Fixture.now, updatedAt: Fixture.now
    )
    reminder.autoRun = mode
    reminder.trigger = trigger
    return reminder
}

private func run(_ reminder: Reminder, state: AutoRun.State, forDueAt: Date? = nil) -> AutoRun {
    AutoRun(
        id: "run-\(reminder.id)", reminderId: reminder.id, forDueAt: forDueAt ?? reminder.dueAt, sessionId: reminder.sessionId,
        mode: .read, startedAt: Fixture.now, state: state
    )
}

private func decide(
    _ reminders: [Reminder], lastRuns: [String: AutoRun] = [:], terminal: Set<String> = [], auto: Set<String> = []
) -> [AutoRunDecision] {
    AutoRunPlanner.decide(
        reminders: reminders, lastRuns: lastRuns, terminalSessions: terminal, autoRunSessions: auto, now: Fixture.now
    )
}

struct AutoRunPlannerTests {
    @Test func startsWhenDue() {
        let due = autoReminder("a")
        #expect(decide([due]) == [.start(due)])
    }

    @Test func notBeforeDue() {
        #expect(decide([autoReminder("a", at: "2026-10-01 11:00")]).isEmpty)
    }

    @Test func notWhileWaitingForTrigger() {
        let waiting = autoReminder("a", trigger: "mr-merged")
        #expect(waiting.isWaiting)
        #expect(decide([waiting]).isEmpty)
    }

    @Test func notWithoutAutoRunOrWhenDone() {
        #expect(decide([autoReminder("a", mode: nil), autoReminder("b", status: .done)]).isEmpty)
    }

    @Test func onceForDueDate() {
        let due = autoReminder("a")
        #expect(decide([due], lastRuns: ["a": run(due, state: .succeeded)]).isEmpty)
    }

    @Test func rescheduledRunsAgain() {
        var due = autoReminder("a")
        let old = run(due, state: .succeeded)
        due.dueAt = Fixture.date("2026-10-01 10:30")
        #expect(decide([due], lastRuns: ["a": old]) == [.start(due)])
    }

    @Test func interruptedRunCountsForDueDate() {
        let due = autoReminder("a")
        #expect(decide([due], lastRuns: ["a": run(due, state: .failed)]).isEmpty)
    }

    @Test func cancelledCountsForDueDate() {
        let due = autoReminder("a")
        #expect(decide([due], lastRuns: ["a": run(due, state: .cancelled)]).isEmpty)
    }

    @Test func runningCountsEvenForAnotherDueDate() {
        let due = autoReminder("a")
        let running = run(due, state: .running, forDueAt: Fixture.date("2026-10-01 09:00"))
        #expect(AutoRunPlanner.hasRun(due, lastRun: running))
        #expect(decide([due], lastRuns: ["a": running]).isEmpty)
    }

    @Test func skipsLiveTerminalSession() {
        let due = autoReminder("a", session: "s1")
        #expect(decide([due], terminal: ["s1"]) == [.skip(due)])
    }

    @Test func waitsForOwnRunOnSession() {
        let due = autoReminder("a", session: "s1")
        #expect(decide([due], terminal: ["s1"], auto: ["s1"]).isEmpty)
    }

    @Test func oneRunPerSession() {
        let first = autoReminder("b", at: "2026-10-01 09:00", session: "s1")
        let second = autoReminder("a", at: "2026-10-01 10:00", session: "s1")
        #expect(decide([second, first]) == [.start(first)])
    }

    @Test func noSessionStarts() {
        let one = autoReminder("a", session: nil)
        let two = autoReminder("b", session: nil)
        #expect(decide([one, two]) == [.start(one), .start(two)])
    }

    @Test func nextDueIgnoresRan() {
        let ran = autoReminder("a", at: "2026-10-01 11:00")
        let later = autoReminder("b", at: "2026-10-01 12:00")
        let sooner = autoReminder("c", at: "2026-10-01 11:30", trigger: "mr-merged")
        let past = autoReminder("d", at: "2026-10-01 10:00")
        let next = AutoRunPlanner.nextDue(
            reminders: [ran, later, sooner, past], lastRuns: ["a": run(ran, state: .succeeded)], now: Fixture.now
        )
        #expect(next == later.dueAt)
        #expect(AutoRunPlanner.nextDue(reminders: [], lastRuns: [:], now: Fixture.now) == nil)
    }
}
