import Foundation
import Testing
@testable import TicklerCore

/// Fixed clock: Thursday 2026-10-01 10:45 in Paris.
enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar
    }()

    static let now = date("2026-10-01 10:45")

    static func date(_ value: String) -> Date {
        StrictDate.parse(value, calendar: calendar)!
    }

    static func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tickler-tests-\(UUID().uuidString)")
            .appendingPathComponent("tickler.sqlite").path
    }

    static func store(path: String = temporaryDatabasePath(), now: Date = Fixture.now) throws -> ReminderStore {
        try ReminderStore(database: TicklerDatabase(path: path), calendar: calendar, now: { now }, onChange: {})
    }

    static func draft(_ title: String, at due: String, notes: String = "", cwd: String? = nil) -> ReminderDraft {
        ReminderDraft(title: title, notes: notes, dueAt: date(due), cwd: cwd)
    }
}

struct ReminderStoreTests {
    @Test func addThenGetRoundTrips() throws {
        let store = try Fixture.store()
        let draft = ReminderDraft(
            title: "OPS-2204: check le dashboard CTO",
            notes: "Epic https://acme.atlassian.net/browse/OPS-2204",
            dueAt: Fixture.date("2026-10-01 11:00"),
            links: ["https://grafana.example.com/d/rollout-readiness"],
            sessionId: "5b26f281-1806-47aa-8842-0e264f7b9d35",
            cwd: "/Users/you/src/platform-services",
            source: .claude
        )
        let added = try store.add(draft)
        #expect(added.id.count == 6)
        #expect(added.status == .open)
        #expect(added.originalDueAt == added.dueAt)
        #expect(added.createdAt == Fixture.now)

        let fetched = try #require(try store.get(added.id))
        #expect(fetched == added)
        #expect(fetched.project == "platform-services")
        #expect(try store.links(for: added.id).map(\.label) == ["OPS-2204", "rollout-readiness"])
    }

    @Test func getUnknownReturnsNil() throws {
        #expect(try Fixture.store().get("zzzzzz") == nil)
    }

    @Test func rescheduleKeepsOriginalDueAndCounts() throws {
        let store = try Fixture.store()
        let added = try store.add(Fixture.draft("a", at: "2026-10-01 11:00"))
        _ = try store.reschedule(added.id, to: Fixture.date("2026-10-01 12:00"))
        let twice = try store.reschedule(added.id, to: Fixture.date("2026-10-02 09:30"))
        #expect(twice.dueAt == Fixture.date("2026-10-02 09:30"))
        #expect(twice.originalDueAt == Fixture.date("2026-10-01 11:00"))
        #expect(twice.rescheduleCount == 2)
    }

    @Test func rescheduleClearsNotifiedAt() throws {
        let store = try Fixture.store()
        let added = try store.add(Fixture.draft("a", at: "2026-10-01 09:00"))
        try store.markNotified([added.id], at: Fixture.now)
        let moved = try store.reschedule(added.id, to: Fixture.date("2026-10-01 12:00"))
        #expect(moved.notifiedAt == nil)
    }

    @Test func doneAndDeletedLeaveTheOpenList() throws {
        let store = try Fixture.store()
        let first = try store.add(Fixture.draft("done one", at: "2026-10-01 11:00"))
        let second = try store.add(Fixture.draft("deleted one", at: "2026-10-01 12:00"))
        let third = try store.add(Fixture.draft("kept", at: "2026-10-01 13:00"))
        let done = try store.markDone(first.id)
        #expect(done.doneAt == Fixture.now)
        try store.delete(second.id)

        #expect(try store.list(ReminderFilter(due: .all)).map(\.id) == [third.id])
        #expect(try store.list(ReminderFilter(due: .all, status: .done)).map(\.id) == [first.id])
        #expect(try store.get(second.id)?.status == .deleted)
    }

    @Test func operationsOnUnknownIdThrowNotFound() throws {
        let store = try Fixture.store()
        #expect(throws: StoreError.notFound("zzzzzz")) { try store.markDone("zzzzzz") }
        #expect(throws: StoreError.notFound("zzzzzz")) { try store.reschedule("zzzzzz", to: Fixture.now) }
    }

    @Test func dueScopes() throws {
        let store = try Fixture.store()
        let yesterday = try store.add(Fixture.draft("yesterday", at: "2026-09-30 15:00"))
        let earlier = try store.add(Fixture.draft("earlier today", at: "2026-10-01 09:30"))
        let later = try store.add(Fixture.draft("later today", at: "2026-10-01 23:30"))
        let tomorrow = try store.add(Fixture.draft("tomorrow", at: "2026-10-02 09:30"))
        let nextWeek = try store.add(Fixture.draft("in 8 days", at: "2026-10-09 09:30"))

        #expect(try store.list(ReminderFilter(due: .today)).map(\.id) == [yesterday.id, earlier.id, later.id])
        #expect(try store.list(ReminderFilter(due: .overdue)).map(\.id) == [yesterday.id, earlier.id])
        #expect(try store.list(ReminderFilter(due: .week)).map(\.id) == [yesterday.id, earlier.id, later.id, tomorrow.id])
        #expect(try store.list(ReminderFilter(due: .all)).count == 5)
        _ = nextWeek
    }

    @Test func projectFilterUsesLastPathComponent() throws {
        let store = try Fixture.store()
        let probe = try store.add(Fixture.draft("probe", at: "2026-10-01 11:00", cwd: "/x/monitoring/prober"))
        _ = try store.add(Fixture.draft("other", at: "2026-10-01 12:00", cwd: "/x/other-project"))
        _ = try store.add(Fixture.draft("no folder", at: "2026-10-01 13:00"))
        #expect(try store.list(ReminderFilter(due: .all, project: "prober")).map(\.id) == [probe.id])
    }

    @Test func updatingNotesRebuildsLinksAndKeepsExplicitOnes() throws {
        let store = try Fixture.store()
        let added = try store.add(ReminderDraft(
            title: "t",
            notes: "old https://acme.atlassian.net/browse/OPS-1",
            dueAt: Fixture.date("2026-10-01 11:00"),
            links: ["https://github.com/o/r/pull/1"]
        ))
        _ = try store.update(added.id, notes: "new https://acme.atlassian.net/browse/OPS-2")
        #expect(try store.links(for: added.id).map(\.label) == ["OPS-2", "r #1"])
    }

    @Test func notifiesOnEveryWrite() throws {
        let counter = Counter()
        let store = try ReminderStore(
            database: TicklerDatabase(path: Fixture.temporaryDatabasePath()),
            calendar: Fixture.calendar,
            now: { Fixture.now },
            onChange: { counter.increment() }
        )
        let added = try store.add(Fixture.draft("a", at: "2026-10-01 11:00"))
        _ = try store.markDone(added.id)
        #expect(counter.value == 2)
    }

    @Test func twoWritersOnTheSameFileBothLand() async throws {
        let path = Fixture.temporaryDatabasePath()
        let app = try Fixture.store(path: path)
        let cli = try Fixture.store(path: path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 20 {
                let writer = index.isMultiple(of: 2) ? app : cli
                group.addTask { _ = try writer.add(Fixture.draft("r\(index)", at: "2026-10-01 11:00")) }
            }
            try await group.waitForAll()
        }
        #expect(try app.list(ReminderFilter(due: .all)).count == 20)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
