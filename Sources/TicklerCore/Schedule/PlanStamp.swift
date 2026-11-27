import CryptoKit
import Foundation

/// What the last full-scope run left: the planner inputs it converged on and until when they plan the same way.
/// Kept in the `setting` table so the app skips the replan the CLI just did.
struct PlanStamp: Codable, Equatable {
    static let key = "planStamp"
    /// Bounds the reuse even when nothing in the plan follows the clock.
    static let maxReuseSeconds: TimeInterval = 3600

    var fingerprint: String
    var validUntil: Date
    var late: [String]
}

/// What a full-scope plan is computed from, besides the clock.
struct PlanInputs {
    var reminders: [Reminder]
    var busy: [DateInterval]
    var schedule: WorkSchedule
    var calendar: Calendar

    /// Every reminder field enters except the two the planner never reads and other writes keep touching.
    func fingerprint() throws -> String {
        var schedule = schedule
        // A Set encodes in a per-process order: the days go in sorted, apart from the schedule.
        let workingDays = schedule.workingDays.sorted()
        schedule.workingDays = []
        let canonical = Canonical(
            reminders: reminders.map(\.planningCopy).sorted { $0.id < $1.id },
            busy: busy,
            schedule: schedule,
            workingDays: workingDays,
            calendar: "\(calendar.identifier)",
            timeZone: calendar.timeZone.identifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(canonical)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Canonical: Encodable {
        var reminders: [Reminder]
        var busy: [DateInterval]
        var schedule: WorkSchedule
        var workingDays: [Int]
        var calendar: String
        var timeZone: String
    }
}

private extension Reminder {
    var planningCopy: Reminder {
        var copy = self
        copy.notifiedAt = nil
        copy.updatedAt = .distantPast
        return copy
    }
}

extension ReminderStore {
    func planStamp() throws -> PlanStamp? {
        try database.pool.read { db in
            try Self.setting(PlanStamp.key, in: db).flatMap { try? JSONDecoder().decode(PlanStamp.self, from: Data($0.utf8)) }
        }
    }

    /// Posts nothing: the stamp is not a change other processes must react to.
    func setPlanStamp(_ stamp: PlanStamp) throws {
        let json = try String(decoding: JSONEncoder().encode(stamp), as: UTF8.self)
        try database.pool.write { db in try Self.setSetting(PlanStamp.key, json, in: db) }
    }
}
