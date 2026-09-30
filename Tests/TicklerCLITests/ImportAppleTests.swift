import Foundation
import Testing
@testable import TicklerCLI

struct ImportAppleTests {
    static let session = "6e077b7d-ca93-41cd-9fe9-c2af0815fc60"
    static let footer = "Session Claude : \(session)\\nReprendre : claude-resume.sh \(session) '/work/git/x'"
    static let json = """
    [
      {"id": "x-apple-reminder://AAA", "name": "OPS-1: check dashboard",
       "body": "See https://acme.atlassian.net/browse/OPS-1\\n\\n\(footer)",
       "due": "2026-10-02T07:30:00.000Z"},
      {"id": "x-apple-reminder://BBB", "name": "Past one", "body": "", "due": "2026-09-30T08:00:00.000Z"},
      {"id": "x-apple-reminder://CCC", "name": "No date", "body": null, "due": null}
    ]
    """

    @Test func decodesJXAOutput() throws {
        let rows = try AppleImport.decode(Data(Self.json.utf8))
        #expect(rows.count == 3)
        #expect(rows[0].id == "x-apple-reminder://AAA")
        #expect(rows[2].body == nil)
        #expect(rows[2].due == nil)
        #expect(throws: CLIError.self) { try AppleImport.decode(Data("not json".utf8)) }
    }

    @Test func parsesDatesWithAndWithoutMilliseconds() {
        let expected = Date(timeIntervalSince1970: 1_790_926_200)
        #expect(AppleImport.parseDue("2026-10-02T07:30:00.000Z") == expected)
        #expect(AppleImport.parseDue("2026-10-02T07:30:00Z") == expected)
        #expect(AppleImport.parseDue(nil) == nil)
        #expect(AppleImport.parseDue("garbage") == nil)
    }

    @Test func importsOnceAndReportsWhatItSkipped() throws {
        var cli = CLIHarness()
        cli.fetchApple = { list in
            #expect(list == "Claude")
            return Data(Self.json.utf8)
        }
        let first = cli.run("import-apple")
        #expect(first.code == 0)
        #expect(first.out.contains("no date, skipped: No date"))
        #expect(first.out.hasSuffix("imported 2, skipped 0 (already imported), 1 without date\n"))

        let second = cli.run("import-apple", "--list", "Claude")
        #expect(second.out == "no date, skipped: No date\nimported 0, skipped 2 (already imported), 1 without date\n")

        let items = try cli.run("list", "--due", "all", "--json").jsonArray()
        #expect(items.count == 2)
        let past = try #require(items.first { $0["title"] as? String == "Past one" })
        #expect(past["overdue"] as? Bool == true)
        let imported = try #require(items.first { $0["title"] as? String == "OPS-1: check dashboard" })
        #expect(imported["sessionId"] as? String == Self.session)
        #expect(imported["cwd"] as? String == "/work/git/x")
        #expect(imported["source"] as? String == "claude")
        #expect(imported["notes"] as? String == "See https://acme.atlassian.net/browse/OPS-1")
        let reminder = try #require(try cli.store().find(externalRef: "x-apple-reminder://AAA"))
        #expect(reminder.dueAt == Date(timeIntervalSince1970: 1_790_926_200))
    }

    @Test func fetchFailureIsRuntimeError() {
        var cli = CLIHarness()
        cli.fetchApple = { _ in throw CLIError.runtime("cannot read the \"Nope\" list of Reminders: not found") }
        let result = cli.run("import-apple", "--list", "Nope")
        #expect(result.code == 1)
        #expect(result.err.hasPrefix("error: cannot read the \"Nope\" list"))
    }
}
