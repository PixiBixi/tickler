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
