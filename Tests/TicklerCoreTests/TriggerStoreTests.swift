import Foundation
import GRDB
import Testing
@testable import TicklerCore

struct TriggerStoreTests {
    private func waiting(_ store: ReminderStore, trigger: Trigger = .merged, at due: String = "2026-10-06 09:30") throws -> Reminder {
        var draft = Fixture.draft("rebase", at: due, notes: "https://gitlab.com/acme/app/-/merge_requests/412")
        draft.trigger = trigger
        return try store.add(draft)
    }

    @Test func addStoresTheTrigger() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store, trigger: .jiraStatus("In Review"))
        let fetched = try #require(try store.get(reminder.id))
        #expect(fetched.trigger == "jira:In Review")
        #expect(fetched.parsedTrigger == .jiraStatus("In Review"))
        #expect(fetched.isWaiting)
        #expect(fetched.firedAt == nil)
    }

    @Test func fireMakesItDueNowWithoutCountingAReschedule() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        try store.markNotified([reminder.id], at: Fixture.now)
        #expect(try store.fire(reminder.id, expected: .merged, reason: "MR !412 merged", at: Fixture.now))
        let fired = try store.require(reminder.id)
        #expect(fired.dueAt == Fixture.now)
        #expect(fired.originalDueAt == Fixture.date("2026-10-06 09:30"))
        #expect(fired.rescheduleCount == 0)
        #expect(fired.notifiedAt == nil)
        #expect(fired.trigger == nil)
        #expect(!fired.isWaiting)
        #expect(fired.firedAt == Fixture.now)
        #expect(fired.firedReason == "MR !412 merged")
    }

    @Test func fireTwiceIsANoOp() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        #expect(try store.fire(reminder.id, expected: .merged, reason: "MR !412 merged", at: Fixture.now))
        #expect(try !store.fire(reminder.id, expected: .merged, reason: "MR !412 merged", at: Fixture.now.addingTimeInterval(300)))
        #expect(try store.require(reminder.id).firedAt == Fixture.now)
    }

    @Test func aReplacedTriggerIsNotFired() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        try store.setTrigger(reminder.id, .approved)
        #expect(try !store.fire(reminder.id, expected: .merged, reason: "MR !412 merged", at: Fixture.now))
        #expect(try store.require(reminder.id).isWaiting)
        #expect(try store.fire(reminder.id, expected: .approved, reason: "MR !412 approved", at: Fixture.now))
    }

    @Test func aDoneOrDeletedReminderNeverFires() throws {
        let store = try Fixture.store()
        let done = try waiting(store)
        try store.markDone(done.id)
        #expect(try !store.fire(done.id, expected: .merged, reason: "x", at: Fixture.now))
        let deleted = try waiting(store)
        try store.delete(deleted.id)
        #expect(try !store.fire(deleted.id, expected: .merged, reason: "x", at: Fixture.now))
    }

    @Test func setTriggerReplacesAndRemoves() throws {
        let store = try Fixture.store()
        let reminder = try waiting(store)
        try store.fire(reminder.id, expected: .merged, reason: "MR !412 merged", at: Fixture.now)
        let rearmed = try store.setTrigger(reminder.id, .approved)
        #expect(rearmed.trigger == "approved")
        #expect(rearmed.firedReason == nil)
        #expect(rearmed.firedAt == nil)
        let cleared = try store.setTrigger(reminder.id, nil)
        #expect(cleared.trigger == nil)
        #expect(cleared.dueAt == Fixture.now)
    }

    @Test func resumeMessageLeadsWithTheReason() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("rebase", at: "2026-10-06 09:30")
        draft.resumePrompt = "Rebase feat/x on main"
        let reminder = try store.add(draft)
        #expect(reminder.resumeMessage == "Rebase feat/x on main")
        var fired = reminder
        fired.firedReason = "MR !412 merged"
        #expect(fired.resumeMessage == "MR !412 merged. Rebase feat/x on main")
        #expect(fired.resumeMessage?.first != "!")
        fired.resumePrompt = nil
        #expect(fired.resumeMessage == "MR !412 merged")
    }

    @Test func waitingRemindersDueLaterGetTheirOwnBucket() throws {
        let store = try Fixture.store()
        let later = try waiting(store, at: "2026-10-06 09:30")
        let today = try waiting(store, at: "2026-10-01 17:00")
        let plain = try store.add(Fixture.draft("plain", at: "2026-10-06 09:30"))
        #expect(DueBucket.of(later, now: Fixture.now, calendar: Fixture.calendar) == .waiting)
        #expect(DueBucket.of(today, now: Fixture.now, calendar: Fixture.calendar) == .today)
        #expect(DueBucket.of(plain, now: Fixture.now, calendar: Fixture.calendar) == .later)
    }

    @Test func migratesAVersionTwoDatabase() throws {
        let path = Fixture.temporaryDatabasePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path)
        try TicklerDatabase.migrator.migrate(queue, upTo: "v2-resume-prompt")
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
        #expect(old.trigger == nil)
        #expect(!old.isWaiting)
    }
}
