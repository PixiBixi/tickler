import CryptoKit
import Foundation

/// The Claude Code skill shipped with this version, installed into the user's skills folder on request.
public enum ClaudeSkill {
    public enum State: Equatable, Sendable {
        case notInstalled
        case upToDate
        /// Installed by an older Tickler and left untouched: replaced without asking.
        case outdated
        /// Edited by the user, or installed by something else: only replaced with `force`.
        case edited
    }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case edited(String)

        public var description: String {
            switch self {
            case let .edited(path):
                "\(path) was edited, or not installed by Tickler: pass --force to replace it"
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

    /// Hash of what Tickler wrote last: tells an untouched older skill from one the user edited.
    static func stamp(in directory: URL) -> URL {
        directory.appendingPathComponent(".tickler-installed")
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func state(in directory: URL) -> State {
        guard let installed = try? String(contentsOf: file(in: directory), encoding: .utf8) else { return .notInstalled }
        if installed == content {
            return .upToDate
        }
        let recorded = try? String(contentsOf: stamp(in: directory), encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == hash(installed) ? .outdated : .edited
    }

    /// Writes the skill. An edited file is only replaced with `force`, so a user's changes are never lost silently.
    @discardableResult
    public static func install(in directory: URL, force: Bool) throws -> State {
        let before = state(in: directory)
        if before == .edited, !force {
            throw InstallError.edited(file(in: directory).path)
        }
        if before != .upToDate {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file(in: directory), options: .atomic)
        }
        try Data((hash(content) + "\n").utf8).write(to: stamp(in: directory), options: .atomic)
        return before
    }
}
