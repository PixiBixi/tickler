import Foundation

/// Finds a JIRA_API_TOKEN already exported by the user's shell files, so setup can offer to import it.
/// Only literal values count: anything computed (`$VAR`, `$(...)`) is left to the shell.
public enum JiraTokenDiscovery {
    public struct Found: Equatable, Sendable {
        public let token: String
        public let path: String
    }

    static let fixedNames = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile"]
    /// Protected folders ask for access through a system prompt: a shell file linked there is skipped, not read.
    static let protectedFolders = ["Documents", "Desktop", "Downloads"]

    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> Found? {
        for file in candidates(home: home, fileManager: fileManager) {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let token = token(in: text) else { continue }
            return Found(token: token, path: "~/" + file.lastPathComponent)
        }
        return nil
    }

    static func candidates(home: URL, fileManager: FileManager) -> [URL] {
        let listed = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extra = listed.filter { name in
            (name.hasPrefix(".zsh_") || name.hasPrefix(".bash_") || name.lowercased().contains("secret"))
                && !name.contains("history") && !name.contains(".bak")
        }.sorted()
        let protected = protectedFolders.map { home.appendingPathComponent($0).resolvingSymlinksInPath().path + "/" }
        return (fixedNames + extra).map { home.appendingPathComponent($0) }.filter { url in
            let resolved = url.resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            return !protected.contains { resolved.hasPrefix($0) }
                && fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    static func token(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.wholeMatch(of: /\s*(?:export\s+)?JIRA_API_TOKEN=(["']?)([^"'\s$`]+)\1\s*(?:#.*)?/) {
                return String(match.2)
            }
        }
        return nil
    }
}
