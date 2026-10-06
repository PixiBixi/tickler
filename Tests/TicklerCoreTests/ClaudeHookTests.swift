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
        #expect(ClaudeHook.command(ticklerPath: "/Users/o'x/tickler") == "'/Users/o'\\''x/tickler' hook session-start")
        #expect(ClaudeHook.command(ticklerPath: "/Users/a$b/tickler") == "'/Users/a$b/tickler' hook session-start")
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
        #expect(once == """
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
              },
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
            ],
            "PreToolUse": []
          }
        }

        """)
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

    @Test(arguments: ["/Users/a b/bin/tickler", "/Users/o'x/bin/tickler"])
    func aQuotedPathRoundTripsToOneEntry(path: String) throws {
        let quoted = ClaudeHook.command(ticklerPath: path)
        try ClaudeHook.install(settings: settings, command: quoted)
        #expect(ClaudeHook.state(settings: settings, command: quoted) == .upToDate)
        #expect(try ClaudeHook.install(settings: settings, command: quoted) == .upToDate)
        #expect(try read().components(separatedBy: "hook session-start").count == 2)
    }

    @Test func anotherBinaryIsNotTickler() throws {
        try write("""
        {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "mytickler hook session-start"}]}]}}
        """)
        #expect(ClaudeHook.state(settings: settings, command: command) == .notInstalled)
        #expect(try !ClaudeHook.uninstall(settings: settings))
    }

    private let shared = """
    {"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [
      {"type": "command", "command": "graft hook"},
      {"type": "command", "command": "/usr/local/bin/tickler hook session-start", "timeout": 3}
    ]}]}}
    """

    @Test func installEditsOnlyTicklersEntryInASharedGroup() throws {
        try write(shared)
        #expect(try ClaudeHook.install(settings: settings, command: command) == .outdated)
        let root = try OrderedJSON.parse(read())
        guard case let .array(groups)? = root["hooks"]?["SessionStart"] else { Issue.record("no groups"); return }
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] == .string("startup"))
        #expect(groups[0]["hooks"] == .array([
            .object([.init(key: "type", value: .string("command")), .init(key: "command", value: .string("graft hook"))]),
            ClaudeHook.entry(command: command),
        ]))
        #expect(ClaudeHook.state(settings: settings, command: command) == .upToDate)
    }

    @Test func uninstallRemovesOnlyTicklersEntryFromASharedGroup() throws {
        try write(shared)
        #expect(try ClaudeHook.uninstall(settings: settings))
        let root = try OrderedJSON.parse(read())
        guard case let .array(groups)? = root["hooks"]?["SessionStart"] else { Issue.record("no groups"); return }
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] == .string("startup"))
        #expect(groups[0]["hooks"]?.printed().contains("graft hook") == true)
        #expect(try read().contains("tickler") == false)
    }

    @Test(arguments: [
        "[]", "{\"hooks\": []}", "{\"hooks\": {\"SessionStart\": {}}}", "{\"hooks\": \"x\"}",
    ])
    func aWrongShapeIsRefusedAndLeftAlone(text: String) throws {
        try write(text)
        #expect(throws: ClaudeHook.InstallError.unexpectedShape(settings.path)) {
            try ClaudeHook.install(settings: settings, command: command)
        }
        #expect(throws: ClaudeHook.InstallError.unexpectedShape(settings.path)) { try ClaudeHook.uninstall(settings: settings) }
        #expect(try read() == text)
    }

    @Test func errorsAreDistinguished() throws {
        try write("{ not json")
        #expect(throws: ClaudeHook.InstallError.invalidSettings(settings.path)) {
            try ClaudeHook.install(settings: settings, command: command)
        }
        try Data([0xFF, 0xFE]).write(to: settings)
        #expect(throws: ClaudeHook.InstallError.unreadable(settings.path)) {
            try ClaudeHook.install(settings: settings, command: command)
        }
    }

    @Test func ticklerPathSkipsRelativePathEntries() throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tickler")
        let planted = !FileManager.default.fileExists(atPath: local.path)
            && FileManager.default.createFile(
                atPath: local.path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
        defer {
            if planted {
                try? FileManager.default.removeItem(at: local)
            }
        }
        #expect(ClaudeHook.ticklerPath(environment: ["PATH": ".::relative:\(bin.path)"]) == nil)
        let tool = bin.appendingPathComponent("tickler")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(ClaudeHook.ticklerPath(environment: ["PATH": ".::relative:\(bin.path)"]) == tool.path)
    }

    @Test func installKeepsTheFilePermissions() throws {
        try write("{}\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        try ClaudeHook.install(settings: settings, command: command)
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
