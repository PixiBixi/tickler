import Foundation

/// The Claude Code skill shipped with this version, installed into the user's skills folder on request.
public enum ClaudeSkill {
    public enum State: Equatable, Sendable {
        case notInstalled
        case upToDate
        /// Another version of the skill, or one the user edited.
        case differs
    }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case differs(String)

        public var description: String {
            switch self {
            case let .differs(path):
                "\(path) differs from this version's skill (edited, or from another version): pass --force to replace it"
            }
        }
    }

    /// `$CLAUDE_CONFIG_DIR/skills/tickler`, else `~/.claude/skills/tickler`.
    public static func directory(environment: [String: String]) -> URL {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".claude")
        return config.appendingPathComponent("skills/tickler")
    }

    public static func file(in directory: URL) -> URL {
        directory.appendingPathComponent("SKILL.md")
    }

    public static func state(in directory: URL) -> State {
        guard let installed = try? String(contentsOf: file(in: directory), encoding: .utf8) else { return .notInstalled }
        return installed == content ? .upToDate : .differs
    }

    /// Writes the skill. A different file is only replaced with `force`, so a user's edits are never lost silently.
    @discardableResult
    public static func install(in directory: URL, force: Bool) throws -> State {
        let before = state(in: directory)
        if before == .differs, !force {
            throw InstallError.differs(file(in: directory).path)
        }
        if before != .upToDate {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file(in: directory), options: .atomic)
        }
        return before
    }
}
