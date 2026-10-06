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

    var database = FileManager.default.temporaryDirectory
        .appendingPathComponent("tickler-cli-\(UUID().uuidString)/tickler.sqlite").path
    var environment: [String: String] = [:]
    var stdin = ""
    var fetchApple: @Sendable (String) throws -> Data = { _ in Data("[]".utf8) }
    var liveRunner: CommandRunning = StubRunner(responses: [:])
    var gitRoot: @Sendable (String) -> String? = { _ in nil }
    var folderExists: @Sendable (String) -> Bool = { _ in true }

    func run(_ arguments: String...) -> CLIResult {
        let out = Output()
        let err = Output()
        let input = stdin
        let apple = fetchApple
        var context = CLIContext(
            environment: environment, currentDirectory: "/work/current", calendar: Self.calendar, now: { Self.now },
            readStdin: { input }, notifyChange: {}, makeDriver: { nil }, fetchAppleReminders: apple, stdout: out, stderr: err
        )
        context.liveRunner = liveRunner
        context.gitRoot = gitRoot
        context.folderExists = folderExists
        let code = TicklerCommand.run(arguments + ["--db", database], context: context)
        return CLIResult(code: code, out: out.captured, err: err.captured)
    }

    func store() throws -> ReminderStore {
        try ReminderStore(database: TicklerDatabase(path: database), calendar: Self.calendar, now: { Self.now }, onChange: {})
    }
}

/// Answers a tool call by the suffix of its command line; throws for the tools listed in `failing`.
struct StubRunner: CommandRunning {
    let responses: [String: String]
    var failing: Set<String> = []

    func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        if failing.contains(tool) {
            throw LiveError.failed(tool: tool, message: "not logged in")
        }
        let line = ([tool] + arguments).joined(separator: " ")
        return Data((responses.first { line.hasSuffix($0.key) }?.value ?? "{}").utf8)
    }
}
