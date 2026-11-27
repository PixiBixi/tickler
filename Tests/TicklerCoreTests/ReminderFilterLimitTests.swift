import Foundation
import Testing
@testable import TicklerCore

struct ReminderFilterLimitTests {
    @Test func limitKeepsTheFirstRowsOfTheSortOrder() throws {
        let store = try Fixture.store()
        for (title, due) in [("c", "2026-10-03 09:00"), ("a", "2026-10-01 09:00"), ("b", "2026-10-02 09:00")] {
            try store.add(Fixture.draft(title, at: due))
        }
        #expect(try store.list(ReminderFilter(due: .all, limit: 2)).map(\.title) == ["a", "b"])
        #expect(try store.list(ReminderFilter(due: .all, limit: 10)).count == 3)
        #expect(try store.list(ReminderFilter(due: .all)).count == 3)
    }

    @Test func limitOnDoneKeepsTheMostRecentlyDone() throws {
        let path = Fixture.temporaryDatabasePath()
        var ids: [String] = []
        for (title, doneAt) in [("first", "2026-10-01 08:00"), ("second", "2026-10-01 09:00"), ("third", "2026-10-01 10:00")] {
            let store = try Fixture.store(path: path, now: Fixture.date(doneAt))
            let reminder = try store.add(Fixture.draft(title, at: "2026-10-05 09:00"))
            try store.markDone(reminder.id)
            ids.append(reminder.id)
        }
        let store = try Fixture.store(path: path)
        let done = try store.list(ReminderFilter(due: .all, status: .done, limit: 2))
        #expect(done.map(\.id) == [ids[2], ids[1]])
    }

    @Test func limitAppliesAfterTheProjectFilter() throws {
        let store = try Fixture.store()
        try store.add(Fixture.draft("a1", at: "2026-10-01 09:00", cwd: "/work/alpha"))
        try store.add(Fixture.draft("b1", at: "2026-10-02 09:00", cwd: "/work/beta"))
        try store.add(Fixture.draft("b2", at: "2026-10-03 09:00", cwd: "/work/beta"))
        let found = try store.list(ReminderFilter(due: .all, project: "beta", limit: 1))
        #expect(found.map(\.title) == ["b1"])
    }
}
