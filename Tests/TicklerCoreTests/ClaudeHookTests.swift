import Foundation
import Testing
@testable import TicklerCore

struct ClaudeHookTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)")
    var settings: URL {
        directory.appendingPathComponent("settings.json")
    }

    let command = "/opt/homebrew/bin/tickler hook session-start"

    private func write(_ text: String, to url: URL? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: url ?? settings, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL? = nil) throws -> String {
        try String(contentsOf: url ?? settings, encoding: .utf8)
    }

    @Test func settingsFileHonorsConfigDir() {
        #expect(ClaudeHook.settingsFile(environment: ["HOME": "/Users/x"]).path == "/Users/x/.claude/settings.json")
        #expect(ClaudeHook.settingsFile(environment: ["HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "/c"]).path == "/c/settings.json")
    }

    @Test func commandQuotesAPathWithSpaces() {
        #expect(ClaudeHook.command(ticklerPath: "/opt/homebrew/bin/tickler") == "/opt/homebrew/bin/tickler hook session-start")
        #expect(ClaudeHook.command(ticklerPath: "/Users/a b/bin/tickler") == "'/Users/a b/bin/tickler' hook session-start")
    }

    @Test func ticklerPathSearchesPathWithoutResolvingSymlinks() throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let real = directory.appendingPathComponent("tickler-real")
        try "#!/bin/sh\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("tickler"), withDestinationURL: real)
        #expect(ClaudeHook.ticklerPath(environment: ["PATH": "/nonexistent:\(bin.path)"]) == bin.appendingPathComponent("tickler").path)
        #expect(ClaudeHook.ticklerPath(environment: ["PATH": "/nonexistent"]) == nil)
    }

    @Test func installCreatesAMissingFile() throws {
        #expect(ClaudeHook.state(settings: settings, command: command) == .notInstalled)
        #expect(try ClaudeHook.install(settings: settings, command: command) == .notInstalled)
        #expect(try read() == """
        {
          "hooks": {
            "SessionStart": [
              {
                "matcher": "startup|clear",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/opt/homebrew/bin/tickler hook session-start",
                    "timeout": 10
                  }
                ]
              }
            ]
          }
        }

        """)
        #expect(ClaudeHook.state(settings: settings, command: command) == .upToDate)
    }

    @Test func installKeepsEverythingElseAndIsIdempotent() throws {
        try write("""
        {
          "model": "opus",
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "graft hook"
                  }
                ]
              }
            ],
            "PreToolUse": []
          }
        }

        """)
        try ClaudeHook.install(settings: settings, command: command)
        let once = try read()
        #expect(once.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"SessionStart\": [\n      {\n        \"hooks\": ["))
        #expect(once.contains("\"command\": \"graft hook\""))
        #expect(once.contains("\"PreToolUse\": []"))
        #expect(try ClaudeHook.install(settings: settings, command: command) == .upToDate)
        #expect(try read() == once)
    }

    @Test func anOlderTicklerGroupIsUpdatedInPlace() throws {
        try ClaudeHook.install(settings: settings, command: "/usr/local/bin/tickler hook session-start")
        #expect(ClaudeHook.state(settings: settings, command: command) == .outdated)
        #expect(try ClaudeHook.install(settings: settings, command: command) == .outdated)
        let text = try read()
        #expect(text.components(separatedBy: "hook session-start").count == 2)
        #expect(text.contains(command))
    }

    @Test func uninstallRemovesOnlyTicklerAndEmptiedContainers() throws {
        try write("{\n  \"model\": \"opus\"\n}\n")
        try ClaudeHook.install(settings: settings, command: command)
        #expect(try ClaudeHook.uninstall(settings: settings))
        #expect(try read() == "{\n  \"model\": \"opus\"\n}\n")
        #expect(try !ClaudeHook.uninstall(settings: settings))
    }

    @Test func invalidSettingsAreRefusedAndLeftAlone() throws {
        try write("{ not json")
        #expect(throws: ClaudeHook.InstallError.self) { try ClaudeHook.install(settings: settings, command: command) }
        #expect(try read() == "{ not json")
    }

    @Test func aSymlinkedSettingsFileKeepsItsLink() throws {
        let target = directory.appendingPathComponent("dotfiles-settings.json")
        try write("{\n  \"model\": \"opus\"\n}\n", to: target)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        try ClaudeHook.install(settings: settings, command: command)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path) == target.path)
        #expect(try read(target).contains(command))
    }

    @Test func anUnreadableSettingsFileIsRefusedAndLeftAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE])
        try bytes.write(to: settings)
        #expect(throws: ClaudeHook.InstallError.self) { try ClaudeHook.install(settings: settings, command: command) }
        #expect(try Data(contentsOf: settings) == bytes)
    }
}
