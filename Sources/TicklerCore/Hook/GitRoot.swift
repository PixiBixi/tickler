import Foundation

public enum GitRoot {
    /// `git rev-parse --show-toplevel` for a folder, nil outside a repository, for a missing folder or after 1 s.
    public static func lookup(_ folder: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder, "rev-parse", "--show-toplevel"]
        guard let outcome = try? ProcessOutcome.run(process, tool: "git", timeout: 1), outcome.status == 0 else { return nil }
        let root = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// `lookup` under one shared budget: once `total` seconds have passed since this call, it returns nil without spawning git.
    public static func budgeted(
        total: TimeInterval = 5,
        clock: @escaping () -> Date = { Date() },
        lookup: @escaping (String) -> String? = { GitRoot.lookup($0) }
    ) -> (String) -> String? {
        let start = clock()
        return { folder in
            clock().timeIntervalSince(start) < total ? lookup(folder) : nil
        }
    }
}
