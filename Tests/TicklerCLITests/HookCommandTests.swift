import Foundation
import Testing
@testable import TicklerCLI
@testable import TicklerCore

struct HookCommandTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hook-home-\(UUID().uuidString)")
    var settings: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    private func cli(stdin: String = "", path: String? = nil) -> CLIHarness {
        var cli = CLIHarness()
        cli.environment = ["HOME": home.path, "PATH": path ?? "/nonexistent"]
        cli.stdin = stdin
        cli.gitRoot = { $0.hasPrefix("/work/platform") ? "/work/platform" : nil }
        cli.folderExists = { _ in true }
        return cli
    }

    private func context(_ result: CLIResult) throws -> String {
        let object = try result.jsonObject()
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "SessionStart")
        return try #require(output["additionalContext"] as? String)
    }

    @Test func sessionStartPrintsTheDigestForTheStdinFolder() throws {
        let cli = cli(stdin: #"{"session_id": "s", "cwd": "/work/platform/charts", "source": "startup"}"#)
        _ = cli.run("add", "check the rollout", "--at", "2026-10-01 17:30", "--session", "s1", "--cwd", "/work/platform")
        let result = cli.run("hook", "session-start")
        #expect(result.code == 0)
        let text = try context(result)
        #expect(text.contains("Tickler reminders for platform"))
        #expect(text.contains("due today 17:30: check the rollout"))
    }

    @Test func nothingToSayPrintsNothing() {
        let result = cli(stdin: #"{"cwd": "/work/platform"}"#).run("hook", "session-start")
        #expect(result.code == 0)
        #expect(result.out.isEmpty)
    }

    @Test func garbageStdinFallsBackToTheCurrentDirectory() {
        let result = cli(stdin: "not json").run("hook", "session-start")
        #expect(result.code == 0)
        #expect(result.err.isEmpty)
    }

    @Test func aBrokenDatabaseStillExitsZeroSilently() {
        var cli = cli(stdin: "{}")
        cli.database = "/dev/null/nope/tickler.sqlite"
        let result = cli.run("hook", "session-start")
        #expect(result.code == 0)
        #expect(result.out.isEmpty)
        #expect(result.err.isEmpty)
    }

    @Test func installStatusUninstall() throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tickler = bin.appendingPathComponent("tickler")
        try "#!/bin/sh\n".write(to: tickler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tickler.path)
        let cli = cli(path: bin.path)
        #expect(cli.run("hook", "status").out == "not installed\t\(settings.path)\n")
        #expect(cli.run("hook", "install").out == "installed\t\(settings.path)\n")
        #expect(try String(contentsOf: settings, encoding: .utf8).contains("\(tickler.path) hook session-start"))
        #expect(cli.run("hook", "install").out == "up to date\t\(settings.path)\n")
        #expect(cli.run("hook", "status").out == "installed\t\(settings.path)\n")
        #expect(cli.run("hook", "uninstall").out == "removed\t\(settings.path)\n")
        #expect(cli.run("hook", "uninstall").out == "not installed\t\(settings.path)\n")
    }

    @Test func installWithoutTicklerOnPathFails() {
        let result = cli().run("hook", "install")
        #expect(result.code == 1)
        #expect(result.err.contains("PATH"))
    }
}
