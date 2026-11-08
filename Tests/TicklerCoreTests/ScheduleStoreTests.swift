import Foundation
import GRDB
import Testing
@testable import TicklerCore

struct ScheduleStoreTests {
    @Test func migrationMarksAutoRunFixedAndOthersFlexible() throws {
        let path = Fixture.temporaryDatabasePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path)
        try TicklerDatabase.migrator.migrate(queue, upTo: "v5-fresh")
        try queue.write { db in
            for (id, autoRun) in [("auto22", "'read'"), ("plain2", "NULL")] {
                try db.execute(sql: """
                INSERT INTO reminder (id, title, notes, dueAt, originalDueAt, rescheduleCount, status, source, autoRun,
                                      createdAt, updatedAt)
                VALUES ('\(id)', 't', '', '2026-10-02 13:00:00.000', '2026-10-02 13:00:00.000', 0, 'open', 'claude', \(autoRun),
                        '2026-10-01 08:00:00.000', '2026-10-01 08:00:00.000')
                """)
            }
        }
        try TicklerDatabase.migrator(now: Fixture.now, calendar: Fixture.calendar).migrate(queue)
        try queue.close()
        let store = try Fixture.store(path: path)
        let auto = try store.require("auto22")
        let plain = try store.require("plain2")
        #expect(auto.fixed)
        #expect(auto.notBefore == nil)
        #expect(!plain.fixed)
        #expect(plain.notBefore == Fixture.date("2026-10-02 09:30"))
        #expect(plain.durationMinutes == 15)
    }

    @Test func addCopiesSchedulingFields() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("A", at: "2026-10-01 14:00")
        draft.durationMinutes = 45
        draft.fixed = true
        draft.notBefore = Fixture.date("2026-10-01 12:00")
        draft.deadline = Fixture.date("2026-10-02 12:00")
        let r = try store.require(store.add(draft).id)
        #expect(r.durationMinutes == 45 && r.fixed)
        #expect(r.earliestStart == Fixture.date("2026-10-01 12:00"))
        #expect(!r.isLate)
        #expect(try store.setDeadline(r.id, Fixture.date("2026-10-01 13:00")).isLate)
        #expect(try store.setDuration(r.id, minutes: 20).durationMinutes == 20)
    }

    @Test func placeSkipsChangedRowsAndKeepsRescheduleCount() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        let stale = Placement(reminderId: r.id, from: Fixture.date("2026-10-01 13:00"), to: Fixture.date("2026-10-01 15:00"))
        #expect(try store.place([stale], reason: { _ in .meeting }, at: Fixture.now).isEmpty)
        let fresh = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))
        let ok = try store.place([fresh], reason: { _ in .meeting }, at: Fixture.now)
        #expect(ok.count == 1)
        #expect(try store.require(r.id).rescheduleCount == 0)
        #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-01 15:00"))
        #expect(try store.moves(since: Fixture.now).first?.reason == .meeting)
    }

    @Test func placeSkipsClosedRows() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        try store.markDone(r.id)
        let move = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))
        #expect(try store.place([move], reason: { _ in .meeting }, at: Fixture.now).isEmpty)
        #expect(try store.require(r.id).dueAt == r.dueAt)
    }

    @Test func placeWithNilReasonWritesNoMove() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        let move = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))
        #expect(try store.place([move], reason: { _ in nil }, at: Fixture.now).isEmpty)
        #expect(try store.require(r.id).dueAt == Fixture.date("2026-10-01 15:00"))
        #expect(try store.moves(since: .distantPast, includeMigration: true).isEmpty)
    }

    @Test func movesHideMigrationAndMarkSeen() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        let first = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))
        try store.place([first], reason: { _ in .migration }, at: Fixture.now)
        #expect(try store.moves(since: .distantPast).isEmpty)
        #expect(try store.moves(since: .distantPast, includeMigration: true).count == 1)
        try store.markMovesSeen(reminderId: r.id)
        #expect(try store.moves(since: .distantPast, includeMigration: true).allSatisfy(\.seen))
    }

    @Test func rescheduleSetsNotBeforeOnFlexibleOnly() throws {
        let store = try Fixture.store()
        let flexible = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        let target = Fixture.date("2026-10-02 11:00")
        let moved = try store.reschedule(flexible.id, to: target)
        #expect(moved.notBefore == target && moved.dueAt == target && moved.rescheduleCount == 1)
        var draft = Fixture.draft("B", at: "2026-10-01 14:00")
        draft.fixed = true
        let pinned = try store.add(draft)
        let pinnedMoved = try store.reschedule(pinned.id, to: target)
        #expect(pinnedMoved.notBefore == nil && pinnedMoved.dueAt == target && pinnedMoved.rescheduleCount == 1)
    }

    @Test func cannotUnfixAutoRun() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("A", at: "2026-10-01 14:00", cwd: "/tmp/p")
        draft.resumePrompt = "go"
        draft.autoRun = .read
        let r = try store.add(draft)
        #expect(throws: StoreError.invalid("fixed by auto-run")) { try store.setFixed(r.id, false) }
        let plain = try store.add(Fixture.draft("B", at: "2026-10-01 14:00"))
        #expect(try store.setFixed(plain.id, true).fixed)
        #expect(try store.setFixed(plain.id, false).fixed == false)
    }

    @Test func replaceBusyStampsSnapshot() throws {
        let store = try Fixture.store()
        let first = DateInterval(start: Fixture.date("2026-10-01 11:00"), end: Fixture.date("2026-10-01 12:00"))
        let second = DateInterval(start: Fixture.date("2026-10-01 14:00"), end: Fixture.date("2026-10-01 15:00"))
        try store.replaceBusy([second, first], at: Fixture.now)
        #expect(try store.busy() == [first, second])
        #expect(try store.busySnapshotAt() == Fixture.now)
        try store.replaceBusy([first], at: Fixture.now)
        #expect(try store.busy() == [first])
    }

    @Test func conflictsRecordedOnce() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        let interval = DateInterval(start: Fixture.date("2026-10-01 14:00"), end: Fixture.date("2026-10-01 15:00"))
        let conflict = ScheduleConflict(reminderId: r.id, interval: interval)
        #expect(try store.recordConflicts([conflict], at: Fixture.now) == [conflict])
        #expect(try store.recordConflicts([conflict], at: Fixture.now).isEmpty)
    }

    @Test func conflictMarksStopWhenTheIntervalEnds() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        let interval = DateInterval(start: Fixture.date("2026-10-01 14:00"), end: Fixture.date("2026-10-01 15:00"))
        try store.recordConflicts([ScheduleConflict(reminderId: r.id, interval: interval)], at: Fixture.now)
        #expect(try store.conflictedReminderIds(endingAfter: Fixture.date("2026-10-01 14:30")) == [r.id])
        #expect(try store.conflictedReminderIds(endingAfter: Fixture.date("2026-10-01 15:00")).isEmpty)
    }
}

struct SchedulePlaceAnchorTests {
    @Test func placeAnchorsARowWithoutNotBefore() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 14:00"))
        #expect(r.notBefore == nil)
        let move = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))
        try store.place([move], reason: { _ in nil }, at: Fixture.now)
        #expect(try store.require(r.id).notBefore == Fixture.date("2026-10-01 14:00"))
    }

    @Test func placeKeepsAnExistingNotBefore() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("A", at: "2026-10-01 14:00")
        draft.notBefore = Fixture.date("2026-10-01 12:00")
        let r = try store.add(draft)
        let move = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 15:00"))
        try store.place([move], reason: { _ in nil }, at: Fixture.now)
        #expect(try store.require(r.id).notBefore == Fixture.date("2026-10-01 12:00"))
    }

    @Test func placeSkipsARowThePlannerReadDifferently() throws {
        let store = try Fixture.store()
        let r = try store.add(Fixture.draft("A", at: "2026-10-01 15:00"))
        let read = try store.require(r.id)
        try store.setDuration(r.id, minutes: 90)
        let move = Placement(reminderId: r.id, from: r.dueAt, to: Fixture.date("2026-10-01 11:00"))
        #expect(try store.place([move], expecting: [r.id: read], reason: { _ in .meeting }, at: Fixture.now).isEmpty)
        #expect(try store.require(r.id).dueAt == r.dueAt)
    }
}
