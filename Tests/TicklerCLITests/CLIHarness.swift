import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct CLIResult {
    let code: Int32
    let out: String
    let err: String

    func jsonObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func jsonArray() throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
    }
}

/// Runs the command in-process against a temporary database, with a fixed clock: Thursday 2026-10-01 10:45 in Paris.
struct CLIHarness {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    static let now = StrictDate.parse("2026-10-01 10:45", calendar: calendar)!

    let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("tickler-cli-\(UUID().uuidString)/tickler.sqlite").path
    var environment: [String: String] = [:]
    var stdin = ""

    func run(_ arguments: String...) -> CLIResult {
        let out = Output()
        let err = Output()
        let input = stdin
        let context = CLIContext(
            environment: environment, currentDirectory: "/work/current", calendar: Self.calendar, now: { Self.now },
            readStdin: { input }, notifyChange: {}, makeDriver: { nil }, stdout: out, stderr: err
        )
        let code = TicklerCommand.run(arguments + ["--db", database], context: context)
        return CLIResult(code: code, out: out.captured, err: err.captured)
    }

    func store() throws -> ReminderStore {
        try ReminderStore(database: TicklerDatabase(path: database), calendar: Self.calendar, now: { Self.now }, onChange: {})
    }
}
