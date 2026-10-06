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
        case unreadable(String)
        case unexpectedShape(String)

        public var description: String {
            switch self {
            case let .invalidSettings(path): "\(path) is not valid JSON: fix it, then run tickler hook install again"
            case let .unreadable(path): "\(path) is unreadable: fix it, then run tickler hook install again"
            case let .unexpectedShape(path): "\(path) has an unexpected shape: fix it, then run tickler hook install again"
            }
        }
    }

    static let matcher = "startup|clear"

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public static func settingsFile(environment: [String: String]) -> URL {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".claude")
        return config.appendingPathComponent("settings.json")
    }

    /// The first executable `tickler` on an absolute PATH entry, as found: a Homebrew symlink survives upgrades, its target does not.
    public static func ticklerPath(environment: [String: String]) -> String? {
        (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/tickler" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func command(ticklerPath: String) -> String {
        let safe = ticklerPath.unicodeScalars
            .allSatisfy { "A" ... "Z" ~= $0 || "a" ... "z" ~= $0 || "0" ... "9" ~= $0 || "/._+-".unicodeScalars.contains($0) }
        let path = safe ? ticklerPath : "'" + ticklerPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(path) hook session-start"
    }

    /// Splits a command into its first shell word (single quotes and `\'` undone) and the rest.
    static func firstWord(of command: String) -> (word: String, rest: String) {
        var word = ""
        var quoted = false
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let char = command[index]
            if escaped {
                word.append(char)
                escaped = false
            } else if quoted {
                if char == "'" {
                    quoted = false
                } else {
                    word.append(char)
                }
            } else if char == "'" {
                quoted = true
            } else if char == "\\" {
                escaped = true
            } else if char == " " {
                break
            } else {
                word.append(char)
            }
            index = command.index(after: index)
        }
        return (word, String(command[index...]).trimmingCharacters(in: .whitespaces))
    }

    static func isTickler(command: String) -> Bool {
        let (word, rest) = firstWord(of: command)
        return word.split(separator: "/").last == "tickler" && rest == "hook session-start"
    }

    static func entry(command: String) -> OrderedJSON {
        .object([
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(command)),
            .init(key: "timeout", value: .number("10")),
        ])
    }

    static func group(command: String) -> OrderedJSON {
        .object([
            .init(key: "matcher", value: .string(matcher)),
            .init(key: "hooks", value: .array([entry(command: command)])),
        ])
    }

    static func hooks(of group: OrderedJSON) -> [OrderedJSON] {
        guard case let .array(hooks)? = group["hooks"] else { return [] }
        return hooks
    }

    /// Position of Tickler's hook entry: its SessionStart group and its place in that group.
    static func ticklerEntry(in groups: [OrderedJSON]) -> (group: Int, hook: Int)? {
        for (position, group) in groups.enumerated() {
            let found = hooks(of: group).firstIndex { hook in
                guard case let .string(command)? = hook["command"] else { return false }
                return isTickler(command: command)
            }
            if let found {
                return (position, found)
            }
        }
        return nil
    }

    /// Refuses a root, `hooks` or `SessionStart` of the wrong type rather than overwriting it.
    static func sessionStartGroups(_ root: OrderedJSON, settings: URL) throws -> [OrderedJSON] {
        guard case .object = root else { throw InstallError.unexpectedShape(settings.path) }
        guard let hooks = root["hooks"] else { return [] }
        guard case .object = hooks else { throw InstallError.unexpectedShape(settings.path) }
        guard let groups = hooks["SessionStart"] else { return [] }
        guard case let .array(items) = groups else { throw InstallError.unexpectedShape(settings.path) }
        return items
    }

    static func current(_ groups: [OrderedJSON], at place: (group: Int, hook: Int)) -> OrderedJSON {
        hooks(of: groups[place.group])[place.hook]
    }

    public static func state(settings: URL, command: String) -> State {
        guard let root = try? load(settings), let groups = try? sessionStartGroups(root, settings: settings),
              let place = ticklerEntry(in: groups) else { return .notInstalled }
        return current(groups, at: place) == entry(command: command) ? .upToDate : .outdated
    }

    @discardableResult
    public static func install(settings: URL, command: String) throws -> State {
        let root = try load(settings)
        var groups = try sessionStartGroups(root, settings: settings)
        let before: State
        if let place = ticklerEntry(in: groups) {
            before = current(groups, at: place) == entry(command: command) ? .upToDate : .outdated
            var hooks = hooks(of: groups[place.group])
            hooks[place.hook] = entry(command: command)
            groups[place.group] = groups[place.group].setting("hooks", to: .array(hooks))
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
        var groups = try sessionStartGroups(root, settings: settings)
        guard let place = ticklerEntry(in: groups) else { return false }
        var remaining = hooks(of: groups[place.group])
        remaining.remove(at: place.hook)
        if remaining.isEmpty {
            groups.remove(at: place.group)
        } else {
            groups[place.group] = groups[place.group].setting("hooks", to: .array(remaining))
        }
        var hooks = root["hooks"] ?? .object([])
        hooks = groups.isEmpty ? hooks.removing("SessionStart") : hooks.setting("SessionStart", to: .array(groups))
        let emptied = hooks == .object([])
        try save(emptied ? root.removing("hooks") : root.setting("hooks", to: hooks), to: settings)
        return true
    }

    /// A missing file is an empty object; anything unreadable or unparsable is refused, never overwritten.
    static func load(_ settings: URL) throws -> OrderedJSON {
        let target = settings.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return .object([]) }
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { throw InstallError.unreadable(settings.path) }
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
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try Data((root.printed() + "\n").utf8).write(to: target, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }
}
