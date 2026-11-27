import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct ListJSONTests {
    @Test func listJSONMatchesPerReminderShow() throws {
        let cli = CLIHarness()
        _ = cli.run("add", "One", "--at", "2026-10-02 09:00", "--notes", "see https://github.com/acme/repo/pull/7")
        _ = cli.run("add", "Two", "--at", "2026-10-03 09:00", "--cwd", "/work/git/x")
        _ = cli.run("add", "Three", "--at", "2026-10-04 09:00", "--notes", "https://example.com/a")
        let list = cli.run("list", "--due", "all", "--json")
        let objects = try list.jsonArray()
        #expect(objects.count == 3)
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for object in objects {
            let id = try #require(object["id"] as? String)
            let shown = cli.run("show", id, "--json").out.trimmingCharacters(in: .newlines)
            let element = try String(decoding: JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
            #expect(element == shown)
        }
        #expect(list.out.contains("https://github.com/acme/repo/pull/7"))
    }
}
