import Foundation

/// Where Claude Code keeps its configuration, and how Tickler writes into it without breaking a user's dotfiles links.
public enum ClaudeConfig {
    public enum WriteError: Error, Equatable {
        case danglingSymlink(String)
    }

    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func directory(environment: [String: String]) -> URL {
        environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// A link whose target is gone is never replaced by a regular file: the owner restores the target.
    static func refuseDanglingSymlink(_ file: URL) throws {
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: file.path) else { return }
        let target = URL(fileURLWithPath: destination, relativeTo: file.deletingLastPathComponent())
        guard manager.fileExists(atPath: target.path) else { throw WriteError.danglingSymlink(file.path) }
    }

    /// Writes the symlink's target atomically and keeps its permissions, so a file kept in a dotfiles repository stays linked.
    static func write(_ data: Data, to file: URL) throws {
        try refuseDanglingSymlink(file)
        let target = file.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }
}
