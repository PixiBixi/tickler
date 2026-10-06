# Session Start Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Claude Code session starts, a `SessionStart` hook tells Claude, in a few lines with `tickler://` links, what Tickler holds for the session's repository, plus a count of overdue reminders elsewhere.

**Architecture:** Pure core units build the text (`SessionDigest`) and edit the settings file (`OrderedJSON`, `ClaudeHook`). The CLI gets a `hook` command group (`session-start`, `install`, `status`, `uninstall`). The app learns `tickler://view/<filter>` and gets an install row in Settings.

**Tech Stack:** Swift 6, SwiftPM (TicklerCore, TicklerCLI), swift-argument-parser, GRDB, Swift Testing, SwiftUI app built with XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-06-tickler-session-start-hook-design.md`

## Global Constraints

- Hook group installed: `{"matcher": "startup|clear", "hooks": [{"type": "command", "command": "<tickler path> hook session-start", "timeout": 10}]}`.
- Hook output: `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "<text>"}}`, or nothing. `tickler hook session-start` always exits 0.
- At most 8 repository lines, then `- and N more: [open today in Tickler](tickler://view/today)`. Titles cut to one line of at most 100 characters. Never notes, links or live status in the output.
- Git root lookup: `git -C <folder> rev-parse --show-toplevel`, 2 s timeout.
- Settings file: `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`; follow the symlink, write the target atomically, keep key order and 2-space indentation.
- App URL: `tickler://view/<today|week|overdue|all|done>`.
- CLI output English; app strings English with French in `App/Resources/Localizable.xcstrings`.
- `skills/tickler/SKILL.md` is embedded by `scripts/embed-skill.sh`; never edit `SkillContent.swift` by hand.
- Conventional Commits, one scope per commit, signed. Never push.
- No em dash, en dash or bullet character in code, comments, docs or strings. Comments 1 to 3 lines.
- Read `CLAUDE.md` at the repo root first: it lists the lint limits (line 140, complexity 15) and the traps.

## Review Focus

1. A settings file with other `SessionStart` groups, or an older Tickler group with another path: install must update in place, never duplicate or drop others (pinned in Task 2).
2. The owner's real settings file is a symlink into a dotfiles repository: the symlink must survive, the target gets the change (pinned in Task 2).
3. A database that cannot be opened or a garbage stdin: the hook prints nothing and exits 0 (pinned in Task 4).
4. A session started in a subfolder of a repository: reminders created at the repository root are attached (pinned in Task 3).
5. A reminder title with a newline or 300 characters: one line, cut at 100 (pinned in Task 3).

---

### Task 1: `OrderedJSON`

**Files:**
- Create: `Sources/TicklerCore/Hook/OrderedJSON.swift`
- Test: `Tests/TicklerCoreTests/OrderedJSONTests.swift`

**Interfaces:**
- Produces: `public indirect enum OrderedJSON: Equatable, Sendable { case object([Member]), array([OrderedJSON]), string(String), number(String), bool(Bool), null }`; `public struct Member: Equatable, Sendable { public var key: String; public var value: OrderedJSON }`; `static func parse(_ text: String) throws -> OrderedJSON` (throws `OrderedJSONError.invalid(offset:)`); `func printed() -> String` (no trailing newline); `subscript(key: String) -> OrderedJSON?` (objects only); `func setting(_ key: String, to value: OrderedJSON) -> OrderedJSON` (replaces in place or appends; non-objects returned unchanged); `func removing(_ key: String) -> OrderedJSON`.

Printing follows `JSON.stringify(value, null, 2)`, the format Claude Code writes: 2-space indent, `"key": value`, one element per line, `{}` and `[]` when empty, numbers as originally spelled, strings escaping only `"`, `\`, and control characters (`\b \f \n \r \t`, others as lowercase `\u00xx`); `/` and non-ASCII are not escaped.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TicklerCore

struct OrderedJSONTests {
    private let settings = #"""
    {
      "includeCoAuthoredBy": false,
      "permissions": {
        "allow": [
          "Bash(cat:*)",
          "Bash(gh pr view:*)"
        ],
        "deny": []
      },
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "~/bin/guard.sh \"$1\"",
                "timeout": 5.5
              }
            ]
          }
        ]
      },
      "tui": {},
      "companyAnnouncements": [
        "Déploiement à 14h / ne pas merger",
        "tab\there, esc \u001b, back\\slash"
      ],
      "count": -12e3,
      "nothing": null
    }
    """#

    @Test func roundTripsByteForByte() throws {
        #expect(try OrderedJSON.parse(settings).printed() == settings)
    }

    @Test func keepsKeyOrder() throws {
        guard case let .object(members) = try OrderedJSON.parse(settings) else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == ["includeCoAuthoredBy", "permissions", "model", "hooks", "tui", "companyAnnouncements", "count", "nothing"])
    }

    @Test func decodesEscapes() throws {
        let value = try OrderedJSON.parse(#"{"a": "x\"y\\z\/wé😀\n"}"#)
        #expect(value["a"] == .string("x\"y\\z/wé😀\n"))
    }

    @Test func rejectsInvalidJSON() {
        for text in ["", "{", "{\"a\" 1}", "[1,]", "{\"a\": tru}", "\"unterminated", "{} extra", "{\"a\": \"\u{1}\"}"] {
            #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(text) }
        }
    }

    @Test func settingReplacesInPlaceOrAppends() throws {
        let value = try OrderedJSON.parse(#"{"a": 1, "b": 2}"#)
        #expect(value.setting("a", to: .bool(true)).printed() == "{\n  \"a\": true,\n  \"b\": 2\n}")
        #expect(value.setting("c", to: .null).printed() == "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": null\n}")
        #expect(value.removing("a").printed() == "{\n  \"b\": 2\n}")
        #expect(OrderedJSON.array([]).setting("a", to: .null) == .array([]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OrderedJSONTests`
Expected: build failure, `cannot find 'OrderedJSON' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum OrderedJSONError: Error, Equatable {
    case invalid(offset: Int)
}

/// A JSON value that keeps object key order and number spelling, so a settings file can be edited with a minimal diff.
public indirect enum OrderedJSON: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(key: String, value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw OrderedJSONError.invalid(offset: parser.index) }
        return value
    }

    public subscript(key: String) -> OrderedJSON? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public func setting(_ key: String, to value: OrderedJSON) -> OrderedJSON {
        guard case var .object(members) = self else { return self }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(Member(key: key, value: value))
        }
        return .object(members)
    }

    public func removing(_ key: String) -> OrderedJSON {
        guard case let .object(members) = self else { return self }
        return .object(members.filter { $0.key != key })
    }

    /// `JSON.stringify(value, null, 2)`, the format Claude Code writes its settings in.
    public func printed() -> String {
        var out = ""
        write(into: &out, level: 0)
        return out
    }

    private func write(into out: inout String, level: Int) {
        let pad = String(repeating: "  ", count: level + 1)
        let closing = String(repeating: "  ", count: level)
        switch self {
        case let .object(members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.write(into: &out, level: level + 1)
                out += index < members.count - 1 ? ",\n" : "\n"
            }
            out += closing + "}"
        case let .array(items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, level: level + 1)
                out += index < items.count - 1 ? ",\n" : "\n"
            }
            out += closing + "]"
        case let .string(text): out += Self.quoted(text)
        case let .number(raw): out += raw
        case let .bool(flag): out += flag ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    private var invalid: OrderedJSONError {
        .invalid(offset: index)
    }

    private func peek(_ character: Unicode.Scalar) -> Bool {
        index < bytes.count && bytes[index] == UInt8(ascii: character)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func value() throws -> OrderedJSON {
        guard index < bytes.count else { throw invalid }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return try .string(string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try .number(number())
        }
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else { throw invalid }
        index += expected.count
    }

    private mutating func object() throws -> OrderedJSON {
        index += 1
        var members: [OrderedJSON.Member] = []
        skipWhitespace()
        if peek("}") {
            index += 1
            return .object([])
        }
        while true {
            skipWhitespace()
            guard peek("\"") else { throw invalid }
            let key = try string()
            skipWhitespace()
            guard peek(":") else { throw invalid }
            index += 1
            skipWhitespace()
            try members.append(OrderedJSON.Member(key: key, value: value()))
            skipWhitespace()
            if peek(",") {
                index += 1
            } else if peek("}") {
                index += 1
                return .object(members)
            } else {
                throw invalid
            }
        }
    }

    private mutating func array() throws -> OrderedJSON {
        index += 1
        var items: [OrderedJSON] = []
        skipWhitespace()
        if peek("]") {
            index += 1
            return .array([])
        }
        while true {
            skipWhitespace()
            try items.append(value())
            skipWhitespace()
            if peek(",") {
                index += 1
            } else if peek("]") {
                index += 1
                return .array(items)
            } else {
                throw invalid
            }
        }
    }

    private mutating func string() throws -> String {
        index += 1
        var result = ""
        var start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                result += String(decoding: bytes[start ..< index], as: UTF8.self)
                index += 1
                return result
            }
            if byte < 0x20 {
                throw invalid
            }
            if byte == UInt8(ascii: "\\") {
                result += String(decoding: bytes[start ..< index], as: UTF8.self)
                index += 1
                try result.unicodeScalars.append(contentsOf: escape())
                start = index
                continue
            }
            index += 1
        }
        throw invalid
    }

    /// The scalars of one escape sequence, `index` on the character after the backslash; leaves it after the sequence.
    private mutating func escape() throws -> [Unicode.Scalar] {
        guard index < bytes.count else { throw invalid }
        let simple: [UInt8: Unicode.Scalar] = [
            UInt8(ascii: "\""): "\"", UInt8(ascii: "\\"): "\\", UInt8(ascii: "/"): "/", UInt8(ascii: "b"): "\u{8}",
            UInt8(ascii: "f"): "\u{C}", UInt8(ascii: "n"): "\n", UInt8(ascii: "r"): "\r", UInt8(ascii: "t"): "\t",
        ]
        if let scalar = simple[bytes[index]] {
            index += 1
            return [scalar]
        }
        guard bytes[index] == UInt8(ascii: "u") else { throw invalid }
        index += 1
        let high = try hex4()
        if (0xD800 ..< 0xDC00).contains(high), peek("\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") {
            index += 2
            let low = try hex4()
            guard (0xDC00 ..< 0xE000).contains(low),
                  let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) else { throw invalid }
            return [scalar]
        }
        guard let scalar = Unicode.Scalar(high) else { throw invalid }
        return [scalar]
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16)
        else { throw invalid }
        index += 4
        return value
    }

    private mutating func number() throws -> String {
        let start = index
        let allowed = Set("-+.eE0123456789".utf8)
        while index < bytes.count, allowed.contains(bytes[index]) {
            index += 1
        }
        let raw = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard !raw.isEmpty, Double(raw) != nil else { throw invalid }
        return raw
    }
}
```

If SwiftLint flags `cyclomatic_complexity` or `function_body_length`, split the offending function into private helpers without changing behavior, and record it in the report.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OrderedJSONTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/TicklerCore/Hook/OrderedJSON.swift Tests/TicklerCoreTests/OrderedJSONTests.swift
git commit -m "feat(core): an order-preserving JSON value for settings edits"
```

---

### Task 2: `ClaudeHook` installer

**Files:**
- Create: `Sources/TicklerCore/Hook/ClaudeHook.swift`
- Test: `Tests/TicklerCoreTests/ClaudeHookTests.swift`

**Interfaces:**
- Consumes: `OrderedJSON` (Task 1).
- Produces: `public enum ClaudeHook` with `enum State: Equatable, Sendable { case notInstalled, outdated, upToDate }`; `enum InstallError: Error, Equatable, CustomStringConvertible { case invalidSettings(String) }`; `static func settingsFile(environment: [String: String]) -> URL`; `static func ticklerPath(environment: [String: String]) -> String?`; `static func command(ticklerPath: String) -> String`; `static func state(settings: URL, command: String) -> State`; `@discardableResult static func install(settings: URL, command: String) throws -> State` (the state before); `@discardableResult static func uninstall(settings: URL) throws -> Bool` (whether something was removed).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TicklerCore

struct ClaudeHookTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)")
    var settings: URL { directory.appendingPathComponent("settings.json") }
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClaudeHookTests`
Expected: build failure, `cannot find 'ClaudeHook' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The Claude Code `SessionStart` hook that runs `tickler hook session-start`, kept in the user's settings file.
public enum ClaudeHook {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// Tickler's group is there with another command (an older path) or matcher: install rewrites it in place.
        case outdated
        case upToDate
    }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case invalidSettings(String)

        public var description: String {
            switch self {
            case let .invalidSettings(path): "\(path) is not valid JSON: fix it, then run tickler hook install again"
            }
        }
    }

    static let suffix = "tickler hook session-start"
    static let matcher = "startup|clear"

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public static func settingsFile(environment: [String: String]) -> URL {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".claude")
        return config.appendingPathComponent("settings.json")
    }

    /// The first executable `tickler` on PATH, as found: a Homebrew symlink survives upgrades, its target does not.
    public static func ticklerPath(environment: [String: String]) -> String? {
        (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tickler" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func command(ticklerPath: String) -> String {
        let path = ticklerPath.contains(" ") ? "'\(ticklerPath)'" : ticklerPath
        return "\(path) hook session-start"
    }

    static func group(command: String) -> OrderedJSON {
        .object([
            .init(key: "matcher", value: .string(matcher)),
            .init(key: "hooks", value: .array([.object([
                .init(key: "type", value: .string("command")),
                .init(key: "command", value: .string(command)),
                .init(key: "timeout", value: .number("10")),
            ])])),
        ])
    }

    /// Index of the SessionStart group holding Tickler's hook.
    static func ticklerGroup(in groups: [OrderedJSON]) -> Int? {
        groups.firstIndex { group in
            guard case let .array(hooks)? = group["hooks"] else { return false }
            return hooks.contains { hook in
                guard case let .string(command)? = hook["command"] else { return false }
                return command.hasSuffix(suffix)
            }
        }
    }

    static func sessionStartGroups(_ root: OrderedJSON) -> [OrderedJSON] {
        guard case let .array(groups)? = root["hooks"]?["SessionStart"] else { return [] }
        return groups
    }

    public static func state(settings: URL, command: String) -> State {
        guard let root = try? load(settings) else { return .notInstalled }
        let groups = sessionStartGroups(root)
        guard let index = ticklerGroup(in: groups) else { return .notInstalled }
        return groups[index] == group(command: command) ? .upToDate : .outdated
    }

    @discardableResult
    public static func install(settings: URL, command: String) throws -> State {
        let root = try load(settings)
        var groups = sessionStartGroups(root)
        let before: State
        if let index = ticklerGroup(in: groups) {
            before = groups[index] == group(command: command) ? .upToDate : .outdated
            groups[index] = group(command: command)
        } else {
            before = .notInstalled
            groups.append(group(command: command))
        }
        guard before != .upToDate else { return before }
        let hooks = (root["hooks"] ?? .object([])).setting("SessionStart", to: .array(groups))
        try save(root.setting("hooks", to: hooks), to: settings)
        return before
    }

    @discardableResult
    public static func uninstall(settings: URL) throws -> Bool {
        let root = try load(settings)
        var groups = sessionStartGroups(root)
        guard let index = ticklerGroup(in: groups) else { return false }
        groups.remove(at: index)
        var hooks = root["hooks"] ?? .object([])
        hooks = groups.isEmpty ? hooks.removing("SessionStart") : hooks.setting("SessionStart", to: .array(groups))
        let emptied = hooks == .object([])
        try save(emptied ? root.removing("hooks") : root.setting("hooks", to: hooks), to: settings)
        return true
    }

    /// A missing file is an empty object; anything unparsable is refused, never overwritten.
    static func load(_ settings: URL) throws -> OrderedJSON {
        let target = settings.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { return .object([]) }
        do {
            return try OrderedJSON.parse(text)
        } catch {
            throw InstallError.invalidSettings(settings.path)
        }
    }

    /// Writes the symlink's target, so a settings file kept in a dotfiles repository stays linked.
    static func save(_ root: OrderedJSON, to settings: URL) throws {
        let target = settings.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((root.printed() + "\n").utf8).write(to: target, options: .atomic)
    }
}
```

Note on `load`: a file that exists but cannot be read as UTF-8 also lands in the `try?` branch and would be treated as empty and then overwritten. Before writing, distinguish "does not exist" (`FileManager.default.fileExists(atPath: target.path)` false: empty object) from "exists but unreadable" (throw `invalidSettings`), and add that case to the tests (write bytes `[0xFF, 0xFE]`, expect a throw and the bytes left unchanged).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClaudeHookTests`
Expected: PASS, 10 tests (9 above plus the unreadable-file test).

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add Sources/TicklerCore/Hook/ClaudeHook.swift Tests/TicklerCoreTests/ClaudeHookTests.swift
git commit -m "feat(core): install the SessionStart hook in the Claude Code settings"
```

---

### Task 3: `SessionDigest` and the git root lookup

**Files:**
- Create: `Sources/TicklerCore/Hook/SessionDigest.swift`
- Create: `Sources/TicklerCore/Hook/GitRoot.swift`
- Test: `Tests/TicklerCoreTests/SessionDigestTests.swift`

**Interfaces:**
- Consumes: `Reminder` (`isWaiting`, `trigger`, `firedReason`, `firedAt`, `cwd`), `DueBucket.of(_ reminder:now:calendar:)`, `StrictDate.format(_:calendar:)`, `ProcessOutcome.run(_:tool:timeout:)` (internal, `Sources/TicklerCore/Live/LiveStatusFetcher.swift`).
- Produces: `public enum SessionDigest { static func text(reminders: [Reminder], sessionFolder: String, now: Date, calendar: Calendar, gitRoot: (String) -> String?, folderExists: (String) -> Bool) -> String? }`; `public enum GitRoot { static func lookup(_ folder: String) -> String? }`.

Rules (spec): repository lines in the order fired (open, `firedReason` set, `firedAt == dueAt`, due now or past), overdue (open, due before now, not fired), due later today, waiting (`DueBucket.of(reminder) == .waiting`); at most 8, then the "and N more" line. "Elsewhere" counts open overdue reminders not attached (no `cwd` included). Header only with repository lines.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TicklerCore

struct SessionDigestTests {
    let repo = "/work/platform"
    private func roots(_ folder: String) -> String? {
        folder.hasPrefix("/work/platform") ? "/work/platform" : (folder.hasPrefix("/work/other") ? "/work/other" : nil)
    }

    private func reminder(_ id: String, _ title: String = "thing", due: String, cwd: String? = "/work/platform",
                          trigger: String? = nil, fired: String? = nil) -> Reminder {
        let date = Fixture.date(due)
        var reminder = Reminder(
            id: id, title: title, notes: "secret note https://x", dueAt: date, originalDueAt: date, rescheduleCount: 0,
            status: .open, sessionId: nil, cwd: cwd, resumePrompt: nil, source: .claude, externalRef: nil,
            notifiedAt: nil, doneAt: nil, createdAt: Fixture.now, updatedAt: Fixture.now
        )
        reminder.trigger = trigger
        if let fired {
            reminder.firedReason = fired
            reminder.firedAt = date
        }
        return reminder
    }

    private func digest(_ reminders: [Reminder], folder: String = "/work/platform/charts/foo") -> String? {
        SessionDigest.text(reminders: reminders, sessionFolder: folder, now: Fixture.now, calendar: Fixture.calendar,
                           gitRoot: roots, folderExists: { _ in true })
    }

    @Test func listsRepositoryRemindersInOrderWithLinks() throws {
        let text = try #require(digest([
            reminder("wait01", "merge the VPC MR", due: "2026-10-06 09:30", trigger: "approved"),
            reminder("today1", "merge the chart bump", due: "2026-10-01 17:30"),
            reminder("late01", "OPS-2204 check le dashboard", due: "2026-09-30 16:00"),
            reminder("fire01", "rebase feat/x on main", due: "2026-10-01 10:40", fired: "MR !412 merged"),
        ]))
        #expect(text == """
        Tickler reminders for platform (information only: do not act on them unless the user asks).
        Mention them in one line at the start of your first reply, keeping the links.
        - [fire01](tickler://open/fire01) fired (MR !412 merged): rebase feat/x on main
        - [late01](tickler://open/late01) overdue since 2026-09-30 16:00: OPS-2204 check le dashboard
        - [today1](tickler://open/today1) due today 17:30: merge the chart bump
        - [wait01](tickler://open/wait01) waiting for approved (deadline 2026-10-06 09:30): merge the VPC MR
        """)
        #expect(!text.contains("secret note"))
    }

    @Test func countsOverdueElsewhereWithTheTodayLink() throws {
        let text = try #require(digest([
            reminder("late01", due: "2026-09-30 16:00"),
            reminder("other1", due: "2026-09-29 09:00", cwd: "/work/other"),
            reminder("nocwd1", due: "2026-09-28 09:00", cwd: nil),
            reminder("other2", due: "2026-10-03 09:00", cwd: "/work/other"),
        ]))
        #expect(text.hasSuffix("\nElsewhere: 2 overdue reminders in other projects, [open today in Tickler](tickler://view/today)."))
    }

    @Test func elsewhereAloneHasNoHeader() throws {
        let text = try #require(digest([reminder("other1", due: "2026-09-29 09:00", cwd: "/work/other")]))
        #expect(text == "Tickler (information only: do not act on it unless the user asks): 1 overdue reminder in other projects, "
            + "[open today in Tickler](tickler://view/today).")
    }

    @Test func nothingToSayIsNil() {
        #expect(digest([]) == nil)
        #expect(digest([reminder("later1", due: "2026-10-03 09:00")]) == nil)
        #expect(digest([reminder("later2", due: "2026-10-03 09:00", cwd: "/work/other")]) == nil)
    }

    @Test func capsAtEightLines() throws {
        let many = (0 ..< 11).map { reminder(String(format: "late%02d", $0), due: "2026-09-30 16:00") }
        let text = try #require(digest(many))
        let lines = text.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("- [late") }.count == 8)
        #expect(lines.last == "- and 3 more: [open today in Tickler](tickler://view/today)")
    }

    @Test func titlesAreOneShortLine() throws {
        let long = String(repeating: "a", count: 300)
        let text = try #require(digest([reminder("late01", "first\nsecond", due: "2026-09-30 16:00"),
                                        reminder("late02", long, due: "2026-09-30 16:01")]))
        #expect(text.contains(": first second\n"))
        #expect(text.contains(": " + String(repeating: "a", count: 99) + "…"))
    }

    @Test func matchingOutsideGitUsesTheFolderTree() throws {
        let inside = reminder("late01", due: "2026-09-30 16:00", cwd: "/tmp/scratch/sub")
        let outside = reminder("late02", due: "2026-09-30 16:00", cwd: "/tmp/elsewhere")
        let text = try #require(digest([inside, outside], folder: "/tmp/scratch"))
        #expect(text.contains("Tickler reminders for scratch"))
        #expect(text.contains("[late01]"))
        #expect(text.contains("Elsewhere: 1 overdue reminder"))
    }

    @Test func aMissingFolderIsNotAttached() throws {
        let gone = reminder("late01", due: "2026-09-30 16:00", cwd: "/tmp/scratch/gone")
        let text = try #require(SessionDigest.text(
            reminders: [gone], sessionFolder: "/tmp/scratch", now: Fixture.now, calendar: Fixture.calendar,
            gitRoot: { _ in nil }, folderExists: { $0 != "/tmp/scratch/gone" }
        ))
        #expect(text.hasPrefix("Tickler (information only"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SessionDigestTests`
Expected: build failure, `cannot find 'SessionDigest' in scope`.

- [ ] **Step 3: Implement `GitRoot`**

```swift
import Foundation

public enum GitRoot {
    /// `git rev-parse --show-toplevel` for a folder, nil outside a repository, for a missing folder or after 2 s.
    public static func lookup(_ folder: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder, "rev-parse", "--show-toplevel"]
        guard let outcome = try? ProcessOutcome.run(process, tool: "git", timeout: 2), outcome.status == 0 else { return nil }
        let root = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }
}
```

- [ ] **Step 4: Implement `SessionDigest`**

```swift
import Foundation

/// What a Claude Code session should hear from Tickler when it starts. Only text Tickler builds or the owner wrote.
public enum SessionDigest {
    static let maxLines = 8
    static let todayLink = "[open today in Tickler](tickler://view/today)"

    public static func text(
        reminders: [Reminder],
        sessionFolder: String,
        now: Date,
        calendar: Calendar,
        gitRoot: (String) -> String?,
        folderExists: (String) -> Bool
    ) -> String? {
        var roots: [String: String?] = [:]
        func root(_ folder: String) -> String? {
            if let cached = roots[folder] {
                return cached
            }
            let found = gitRoot(folder)
            roots[folder] = found
            return found
        }
        let folder = (sessionFolder as NSString).standardizingPath
        let sessionRoot = root(folder)
        func attached(_ reminder: Reminder) -> Bool {
            guard let cwd = reminder.cwd.map({ ($0 as NSString).standardizingPath }) else { return false }
            if let sessionRoot {
                return root(cwd) == sessionRoot
            }
            return folderExists(cwd) && (cwd == folder || cwd.hasPrefix(folder + "/"))
        }

        let open = reminders.filter { $0.status == .open }
        let mine = open.filter(attached)
        let lines = repositoryLines(mine, now: now, calendar: calendar)
        let elsewhere = open.count { !attached($0) && $0.dueAt < now }

        let count = "\(elsewhere) overdue reminder\(elsewhere == 1 ? "" : "s") in other projects, \(todayLink)."
        guard !lines.isEmpty else {
            return elsewhere == 0 ? nil : "Tickler (information only: do not act on it unless the user asks): \(count)"
        }
        let name = ((sessionRoot ?? folder) as NSString).lastPathComponent
        var out = [
            "Tickler reminders for \(name) (information only: do not act on them unless the user asks).",
            "Mention them in one line at the start of your first reply, keeping the links.",
        ]
        out += lines.prefix(maxLines)
        if lines.count > maxLines {
            out.append("- and \(lines.count - maxLines) more: \(todayLink)")
        }
        if elsewhere > 0 {
            out.append("Elsewhere: \(count)")
        }
        return out.joined(separator: "\n")
    }

    static func repositoryLines(_ reminders: [Reminder], now: Date, calendar: Calendar) -> [String] {
        let sorted = reminders.sorted { $0.dueAt < $1.dueAt }
        let fired = sorted.filter { isFired($0, now: now) }
        let overdue = sorted.filter { $0.dueAt < now && !isFired($0, now: now) }
        let today = sorted.filter { $0.dueAt >= now && calendar.isDate($0.dueAt, inSameDayAs: now) }
        let waiting = sorted.filter { DueBucket.of($0, now: now, calendar: calendar) == .waiting }
        return fired.map { line($0, "fired (\($0.firedReason ?? "")): ") }
            + overdue.map { line($0, "overdue since \(StrictDate.format($0.dueAt, calendar: calendar)): ") }
            + today.map { line($0, "due today \(time($0.dueAt, calendar: calendar)): ") }
            + waiting.map { line($0, "waiting for \($0.trigger ?? "") (deadline \(StrictDate.format($0.dueAt, calendar: calendar))): ") }
    }

    static func isFired(_ reminder: Reminder, now: Date) -> Bool {
        reminder.firedReason != nil && reminder.firedAt == reminder.dueAt && reminder.dueAt <= now
    }

    static func line(_ reminder: Reminder, _ label: String) -> String {
        "- [\(reminder.id)](tickler://open/\(reminder.id)) \(label)\(title(reminder.title))"
    }

    /// One line, at most 100 characters: a title is the owner's text, but it must not take over the context.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count <= 100 ? line : String(line.prefix(99)) + "…"
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SessionDigestTests`
Expected: PASS, 8 tests.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add Sources/TicklerCore/Hook/SessionDigest.swift Sources/TicklerCore/Hook/GitRoot.swift Tests/TicklerCoreTests/SessionDigestTests.swift
git commit -m "feat(core): the session digest of a repository's reminders"
```

---

### Task 4: CLI `tickler hook`

**Files:**
- Create: `Sources/TicklerCLI/HookCommand.swift`
- Modify: `Sources/TicklerCLI/TicklerCommand.swift` (add `HookCommand.self` to `subcommands`, after `SkillCommand.self`)
- Modify: `Sources/TicklerCLI/CLIContext.swift` (two injectable lookups)
- Test: `Tests/TicklerCLITests/HookCommandTests.swift`

**Interfaces:**
- Consumes: `SessionDigest.text`, `GitRoot.lookup` (Task 3); `ClaudeHook` (Task 2); `CLIContext.readStdin`, `openStore(_:)`.
- Produces: `CLIContext.gitRoot: @Sendable (String) -> String?` (default `GitRoot.lookup`) and `CLIContext.folderExists: @Sendable (String) -> Bool` (default: `FileManager.default.fileExists`); commands `hook session-start`, `hook install`, `hook status`, `hook uninstall`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TicklerCLI
@testable import TicklerCore

struct HookCommandTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hook-home-\(UUID().uuidString)")
    var settings: URL { home.appendingPathComponent(".claude/settings.json") }

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
        let result = cli(stdin: "{}").run("hook", "session-start", "--db", "/dev/null/nope/tickler.sqlite")
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
```

`--db` in `aBrokenDatabaseStillExitsZeroSilently` overrides the harness's own `--db` only if ArgumentParser takes the last occurrence; if it does not, add a `CLIHarness` variant that runs without its default `--db` (for example a `database` property the test can set to the broken path) and use it here.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HookCommandTests`
Expected: build failure, `value of type 'CLIHarness' has no member 'gitRoot'`.

- [ ] **Step 3: Context and harness**. In `CLIContext`, after `liveRunner`:

```swift
    /// Injected so tests need no real repository.
    public var gitRoot: @Sendable (String) -> String? = { GitRoot.lookup($0) }
    public var folderExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
```

In `Tests/TicklerCLITests/CLIHarness.swift`, add `var gitRoot: @Sendable (String) -> String? = { _ in nil }` and `var folderExists: @Sendable (String) -> Bool = { _ in true }`, and set `context.gitRoot = gitRoot` and `context.folderExists = folderExists` next to `context.liveRunner = liveRunner`.

- [ ] **Step 4: The command group**

```swift
import ArgumentParser
import Foundation
import TicklerCore

struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "The Claude Code SessionStart hook that tells Claude about the session's reminders.",
        subcommands: [HookSessionStartCommand.self, HookInstallCommand.self, HookStatusCommand.self, HookUninstallCommand.self]
    )
}

struct HookSessionStartCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "session-start",
        abstract: "Run by Claude Code when a session starts: prints the reminders of the session's repository."
    )

    @OptionGroup var options: GlobalOptions

    /// Never fails: a hook error would greet every session, so any problem prints nothing.
    func execute(_ context: CLIContext) throws {
        let input = (try? JSONSerialization.jsonObject(with: Data(context.readStdin().utf8))) as? [String: Any]
        let folder = (input?["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? context.currentDirectory
        guard let store = try? context.openStore(options),
              let reminders = try? store.list(ReminderFilter(due: .all)),
              let text = SessionDigest.text(
                  reminders: reminders, sessionFolder: folder, now: context.now(), calendar: context.calendar,
                  gitRoot: context.gitRoot, folderExists: context.folderExists
              )
        else { return }
        let output = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        context.stdout.line(String(decoding: data, as: UTF8.self))
    }
}

struct HookInstallCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Add the hook to ~/.claude/settings.json ($CLAUDE_CONFIG_DIR is honored), or update it."
    )

    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let settings = ClaudeHook.settingsFile(environment: context.environment)
        guard let tickler = ClaudeHook.ticklerPath(environment: context.environment) else {
            throw CLIError.runtime("tickler is not on PATH: the hook needs a stable path to run it")
        }
        do {
            switch try ClaudeHook.install(settings: settings, command: ClaudeHook.command(ticklerPath: tickler)) {
            case .notInstalled: context.stdout.line("installed\t\(settings.path)")
            case .outdated: context.stdout.line("updated\t\(settings.path)")
            case .upToDate: context.stdout.line("up to date\t\(settings.path)")
            }
        } catch let error as ClaudeHook.InstallError {
            throw CLIError.runtime(error.description)
        }
    }
}

struct HookStatusCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the hook is installed.")
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let settings = ClaudeHook.settingsFile(environment: context.environment)
        let command = ClaudeHook.ticklerPath(environment: context.environment).map(ClaudeHook.command(ticklerPath:)) ?? ""
        let state = switch ClaudeHook.state(settings: settings, command: command) {
        case .notInstalled: "not installed"
        case .upToDate: "installed"
        case .outdated: command.isEmpty ? "installed" : "outdated, run: tickler hook install"
        }
        context.stdout.line("\(state)\t\(settings.path)")
    }
}

struct HookUninstallCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove the hook from the Claude Code settings.")
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let settings = ClaudeHook.settingsFile(environment: context.environment)
        do {
            let removed = try ClaudeHook.uninstall(settings: settings)
            context.stdout.line("\(removed ? "removed" : "not installed")\t\(settings.path)")
        } catch let error as ClaudeHook.InstallError {
            throw CLIError.runtime(error.description)
        }
    }
}
```

Add `HookCommand.self` after `SkillCommand.self` in `TicklerCommand.configuration.subcommands`.

- [ ] **Step 5: Run the whole suite**

Run: `make test`
Expected: PASS, the 6 new tests included.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add Sources/TicklerCLI Tests/TicklerCLITests
git commit -m "feat(cli): tickler hook session-start, install, status and uninstall"
```

---

### Task 5: App: `tickler://view/<filter>` and the Settings row

**Files:**
- Modify: `App/Sources/Model/AppModel.swift` (new `open(_ url: URL)` next to `reveal(_:)`)
- Modify: `App/Sources/AppDelegate.swift:25-35` and `App/Sources/Views/MainWindow.swift:54-59` (call `open(_:)`)
- Create: `App/Sources/Views/HookInstallRow.swift`
- Modify: `App/Sources/Views/SettingsView.swift` (a section after "Claude Code Skill")
- Modify: `App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ClaudeHook` (Task 2), `SidebarFilter`, `AppModel.reveal(_:)`, `showMainWindow()`.

- [ ] **Step 1: One URL entry point** in `AppModel`, after `reveal(_:)`:

```swift
    /// `tickler://open/<id>` reveals a reminder, `tickler://view/<filter>` opens the window on a sidebar view.
    func open(_ url: URL) {
        guard url.scheme == Tickler.urlScheme else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (url.host(), parts.first) {
        case let ("open", id?):
            reveal(id)
        case let ("view", name?):
            let views: [String: SidebarFilter] = ["today": .today, "week": .week, "overdue": .overdue, "all": .all, "done": .done]
            if let view = views[name] {
                filter = view
                selection = nil
            }
            showMainWindow()
        default:
            break
        }
    }
```

In `AppDelegate.application(_:open:)`, replace the loop body with `AppModel.shared.open(url)` (keep the `MainActor.assumeIsolated` and the scheme filter), and update its doc comment to mention both URLs. In `MainWindow`, replace the `.onOpenURL` body with `model.open(url)`.

- [ ] **Step 2: Settings row**:

```swift
import SwiftUI
import TicklerCore

/// The Claude Code SessionStart hook, the same entry `tickler hook install` writes.
struct HookInstallRow: View {
    @State private var state = ClaudeHook.State.notInstalled
    @State private var error: String?

    private var settings: URL {
        ClaudeHook.settingsFile(environment: ProcessInfo.processInfo.environment)
    }

    /// The app has no shell PATH: look where the cask and `make install` put the CLI.
    private var command: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeHook.ticklerPath(environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"])
            .map(ClaudeHook.command(ticklerPath:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(statusText, systemImage: state == .upToDate ? "checkmark.seal.fill" : "circle.dashed")
                    .foregroundStyle(state == .upToDate ? .green : (state == .notInstalled ? .secondary : .orange))
                Spacer()
                if state != .upToDate {
                    Button(state == .notInstalled ? "Install Hook" : "Update Hook", action: install)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(command == nil)
                }
            }
            Text("Claude hears about this repository's reminders when a session starts.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(verbatim: settings.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if command == nil {
                Text("Install the tickler command first.").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if let error {
                Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .onAppear(perform: refresh)
    }

    private var statusText: LocalizedStringKey {
        switch state {
        case .notInstalled: "Not installed"
        case .outdated: "Installed, with another path"
        case .upToDate: "Installed"
        }
    }

    private func refresh() {
        state = ClaudeHook.state(settings: settings, command: command ?? "")
    }

    private func install() {
        guard let command else { return }
        do {
            try ClaudeHook.install(settings: settings, command: command)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        refresh()
    }
}
```

In `SettingsView`, after the `Section("Claude Code Skill") { SkillInstallRow() }` block, add `Section("Session Start Hook") { HookInstallRow() }`.

- [ ] **Step 3: French strings**: add to `Localizable.xcstrings`, keeping the file's existing key order and format (additions only, verify with `git diff --stat`): `Session Start Hook` = `Hook de démarrage de session`, `Install Hook` = `Installer le hook`, `Update Hook` = `Mettre à jour le hook`, `Installed` = `Installé` (skip if it already exists), `Installed, with another path` = `Installé, avec un autre chemin`, `Claude hears about this repository's reminders when a session starts.` = `Claude est prévenu des rappels de ce dépôt au démarrage d'une session.`, `Install the tickler command first.` = `Installe d'abord la commande tickler.`. `Not installed` already exists for the skill row: reuse it.

- [ ] **Step 4: Build and check by hand**

```bash
make app
make dev
open "tickler://view/overdue"
# expected: the window opens on the Overdue view
open "tickler://view/today"
# expected: the window switches to Today
```

Then open Settings and check the new section shows the hook state. Do not click Install (it would edit the owner's real settings file); report what the row shows.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add App/Sources App/Resources/Localizable.xcstrings
git commit -m "feat(app): tickler://view URLs and the session start hook in Settings"
```

---

### Task 6: README, skill, CLAUDE.md

**Files:**
- Modify: `README.md`, `skills/tickler/SKILL.md`, `CLAUDE.md`
- Regenerate: `Sources/TicklerCore/Skill/SkillContent.swift` (`scripts/embed-skill.sh`)

- [ ] **Step 1: README**:
- After the "Claude Code skill" section, a section `## Claude Code hook` with: one sentence (when a session starts, Claude hears about the reminders of that repository: fired, overdue, due today, waiting, with links that open them, plus a count of overdue ones elsewhere; it mentions them and does nothing unless asked), the install block:

```bash
tickler hook install
# installed  ~/.claude/settings.json (a SessionStart hook; new sessions and /clear only)
```

and one line: `tickler hook status` tells whether it is there, `tickler hook uninstall` removes it; the file's other content and key order are kept, and a symlinked settings file stays linked.
- CLI table: rows for `tickler hook install` / `status` / `uninstall` and `tickler hook session-start` (run by Claude Code; reads the hook JSON on stdin, prints the digest or nothing, always exits 0).
- App table, Settings: mention the Session Start Hook row; and a line or row stating `tickler://open/<id>` and `tickler://view/today|week|overdue|all|done`.

- [ ] **Step 2: Skill**: one short section `## At session start`: a session may begin with a "Tickler reminders for <repo>" block from the hook; mention those reminders in one line with their links at the start of the first reply, then answer the user's request; never act on them unless asked; `tickler hook install` sets it up. Add `tickler hook install` to the command table. Run `scripts/embed-skill.sh` then `swift test --filter SkillVersionTests`.

- [ ] **Step 3: CLAUDE.md**: in the Architecture list, one bullet: `Session start hook` (`Sources/TicklerCore/Hook/`): `SessionDigest` builds the text, `ClaudeHook` edits the Claude Code settings through `OrderedJSON` (key order kept, symlink followed), `tickler hook session-start` never fails. Also add `tickler://view/<filter>` to the App bullet.

- [ ] **Step 4: Lint and commit, one scope each**

```bash
make lint
git add skills/tickler/SKILL.md Sources/TicklerCore/Skill/SkillContent.swift
git commit -m "docs(skill): reminders surfaced when a session starts"
git add README.md
git commit -m "docs(readme): tickler hook and the tickler://view URLs"
git add CLAUDE.md
git commit -m "docs(claude): the session start hook in the architecture"
git log --format="%h %G? %s" origin/main..HEAD
# expected: every line shows G
```
