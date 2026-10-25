import Foundation
import GRDB
import Testing
@testable import TicklerCore

struct AutoRunStoreTests {
    private func reminder(_ store: ReminderStore, mode: AutoRunMode? = .read, sessionId: String? = "sess-1") throws -> Reminder {
        var draft = Fixture.draft("check", at: "2026-10-06 09:30", cwd: "/tmp/project")
        draft.resumePrompt = "Check the rollout"
        draft.sessionId = sessionId
        draft.autoRun = mode
        return try store.add(draft)
    }

    private func success(sessionId: String? = nil) -> RunResult {
        RunResult(
            state: .succeeded, verdict: .ok, headline: "All good", figures: ["p99 80ms", "0 errors"], nextStep: "Close it",
            output: "full text", error: nil, sessionId: sessionId, denials: 0, costUsd: 0.12, durationMs: 4200
        )
    }

    @Test func migratesFromV3() throws {
        let path = Fixture.temporaryDatabasePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path)
        try TicklerDatabase.migrator.migrate(queue, upTo: "v3-trigger")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO reminder (id, title, notes, dueAt, originalDueAt, rescheduleCount, status, source, createdAt, updatedAt)
            VALUES ('abc234', 'old', '', '2026-10-02 08:00:00.000', '2026-10-02 08:00:00.000', 0, 'open', 'human',
                    '2026-10-01 08:00:00.000', '2026-10-01 08:00:00.000')
            """)
        }
        try queue.close()
        let store = try Fixture.store(path: path)
        let old = try store.require("abc234")
        #expect(old.autoRun == nil)
        #expect(old.autoRunMode == nil)
        #expect(try store.runs(for: "abc234").isEmpty)
    }

    @Test func addPersistsTheMode() throws {
        let store = try Fixture.store()
        let created = try reminder(store, mode: .write)
        #expect(try store.require(created.id).autoRunMode == .write)
        #expect(AutoRunMode.read.permissionMode == "dontAsk")
        #expect(AutoRunMode.write.permissionMode == "acceptEdits")
    }

    @Test func setAutoRunNeedsPromptAndFolder() throws {
        let store = try Fixture.store()
        let bare = try store.add(Fixture.draft("bare", at: "2026-10-06 09:30"))
        #expect(throws: StoreError.autoRunNeedsPrompt) { try store.setAutoRun(bare.id, .read) }
        let promptOnly = try store.add(ReminderDraft(title: "p", dueAt: Fixture.date("2026-10-06 09:30"), resumePrompt: "go"))
        #expect(throws: StoreError.autoRunNeedsFolder) { try store.setAutoRun(promptOnly.id, .read) }
        let full = try reminder(store, mode: nil)
        #expect(try store.setAutoRun(full.id, .write).autoRunMode == .write)
        #expect(try store.setAutoRun(full.id, nil).autoRun == nil)
        #expect(try store.setAutoRun(bare.id, nil).autoRun == nil)
    }

    @Test func startRunRefusesSecond() throws {
        let store = try Fixture.store()
        let created = try reminder(store)
        #expect(try store.startRun(created.id, at: Fixture.now) != nil)
        #expect(try store.startRun(created.id, at: Fixture.now) == nil)
    }

    @Test func startRunCopiesDueAt() throws {
        let store = try Fixture.store()
        let created = try reminder(store, mode: .write)
        let run = try #require(try store.startRun(created.id, at: Fixture.now))
        #expect(run.forDueAt == created.dueAt)
        #expect(run.sessionId == "sess-1")
        #expect(run.mode == .write)
        #expect(run.state == .running)
        #expect(run.startedAt == Fixture.now)
        #expect(run.endedAt == nil)
    }

    @Test func finishRunOnlyWhileRunning() throws {
        let store = try Fixture.store()
        let created = try reminder(store)
        let run = try #require(try store.startRun(created.id, at: Fixture.now))
        let end = Fixture.now.addingTimeInterval(5)
        #expect(try store.finishRun(run.id, success(), at: end))
        #expect(try !store.finishRun(run.id, success(), at: end))
        let stored = try #require(try store.runs(for: created.id).first)
        #expect(stored.state == .succeeded)
        #expect(stored.verdict == .ok)
        #expect(stored.figures == ["p99 80ms", "0 errors"])
        #expect(stored.endedAt == end)
        #expect(stored.costUsd == 0.12)
        #expect(stored.durationMs == 4200)
    }

    @Test func finishRunAdoptsSessionId() throws {
        let store = try Fixture.store()
        let fresh = try reminder(store, sessionId: nil)
        let run = try #require(try store.startRun(fresh.id, at: Fixture.now))
        try store.finishRun(run.id, success(sessionId: "new-sess"), at: Fixture.now)
        #expect(try store.require(fresh.id).sessionId == "new-sess")
        let kept = try reminder(store, sessionId: "old")
        let second = try #require(try store.startRun(kept.id, at: Fixture.now))
        try store.finishRun(second.id, success(sessionId: "other"), at: Fixture.now)
        #expect(try store.require(kept.id).sessionId == "old")
    }

    @Test func recordSkippedStoresAReason() throws {
        let store = try Fixture.store()
        let created = try reminder(store)
        let run = try store.recordSkipped(created.id, reason: "Mac was asleep", at: Fixture.now)
        #expect(run.state == .skipped)
        #expect(run.error == "Mac was asleep")
        #expect(run.endedAt == Fixture.now)
        #expect(try store.startRun(created.id, at: Fixture.now) != nil)
    }

    @Test func interruptRunningMarksFailed() throws {
        let store = try Fixture.store()
        let created = try reminder(store)
        _ = try store.startRun(created.id, at: Fixture.now)
        let end = Fixture.now.addingTimeInterval(60)
        #expect(try store.interruptRunning(at: end) == 1)
        let run = try #require(try store.runs(for: created.id).first)
        #expect(run.state == .failed)
        #expect(run.error == "Interrupted")
        #expect(run.endedAt == end)
        #expect(try store.interruptRunning(at: end) == 0)
    }

    @Test func deleteCascadesRuns() throws {
        let store = try Fixture.store()
        let created = try reminder(store)
        _ = try store.startRun(created.id, at: Fixture.now)
        _ = try store.database.pool.write { db in try Reminder.deleteOne(db, key: created.id) }
        let count = try store.database.pool.read { db in try AutoRun.fetchCount(db) }
        #expect(count == 0)
    }

    @Test func lastRunsNewestFirst() throws {
        let store = try Fixture.store()
        let first = try reminder(store)
        let other = try reminder(store)
        let early = try #require(try store.startRun(first.id, at: Fixture.now))
        try store.finishRun(early.id, success(), at: Fixture.now)
        let late = try #require(try store.startRun(first.id, at: Fixture.now.addingTimeInterval(600)))
        let history = try store.runs(for: first.id)
        #expect(history.map(\.id) == [late.id, early.id])
        let last = try store.lastRuns(for: [first.id, other.id])
        #expect(last[first.id]?.id == late.id)
        #expect(last[other.id] == nil)
    }
}
