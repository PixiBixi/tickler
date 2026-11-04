import Foundation
import GRDB
import Testing
@testable import TicklerCore

struct FreshStoreTests {
    @Test func migratesFromV4WithFreshOff() throws {
        let path = Fixture.temporaryDatabasePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path)
        try TicklerDatabase.migrator.migrate(queue, upTo: "v4-auto-run")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO reminder (id, title, notes, dueAt, originalDueAt, rescheduleCount, status, sessionId, source,
                                  createdAt, updatedAt)
            VALUES ('abc234', 'old', '', '2026-10-02 08:00:00.000', '2026-10-02 08:00:00.000', 0, 'open', 'sess-1', 'claude',
                    '2026-10-01 08:00:00.000', '2026-10-01 08:00:00.000')
            """)
        }
        try queue.close()
        let old = try Fixture.store(path: path).require("abc234")
        #expect(old.fresh == false)
        #expect(old.continuedSessionId == "sess-1")
        #expect(old.canResume)
    }

    @Test func addAndSetFreshRoundTrip() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("handoff", at: "2026-10-06 09:30", cwd: "/tmp/project")
        draft.sessionId = "sess-1"
        draft.fresh = true
        let created = try store.add(draft)
        #expect(try store.require(created.id).fresh)
        #expect(created.continuedSessionId == nil)
        #expect(try store.setFresh(created.id, false).fresh == false)
        #expect(try store.require(created.id).continuedSessionId == "sess-1")
    }

    @Test func freshRunsRecordNoSession() throws {
        let store = try Fixture.store()
        var draft = Fixture.draft("check", at: "2026-10-06 09:30", cwd: "/tmp/project")
        draft.sessionId = "sess-1"
        draft.resumePrompt = "Read the handoff"
        draft.autoRun = .read
        draft.fresh = true
        let created = try store.add(draft)
        let run = try #require(try store.startRun(created.id, at: Date()))
        #expect(run.sessionId == nil)
    }

    @Test func freshResumeNeedsOnlyAFolder() throws {
        var reminder = try Fixture.store().add(Fixture.draft("no session", at: "2026-10-06 09:30", cwd: "/tmp/project"))
        #expect(!reminder.canResume)
        reminder.fresh = true
        #expect(reminder.canResume)
        reminder.cwd = nil
        #expect(!reminder.canResume)
    }
}
