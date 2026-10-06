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

    /// A missing file is an empty object; anything unreadable or unparsable is refused, never overwritten.
    static func load(_ settings: URL) throws -> OrderedJSON {
        let target = settings.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return .object([]) }
        do {
            let text = try String(contentsOf: target, encoding: .utf8)
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
