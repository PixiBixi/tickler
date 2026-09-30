import Foundation

/// The CLIs live status relies on, how to install them and how to log in.
public enum ExternalTool: String, CaseIterable, Sendable {
    case glab
    case jira
    case gh

    public var formula: String {
        switch self {
        case .glab: "glab"
        case .jira: "jira-cli"
        case .gh: "gh"
        }
    }

    public var loginCommand: String {
        switch self {
        case .glab: "glab auth login"
        case .jira: "jira init"
        case .gh: "gh auth login"
        }
    }
}

public extension LiveTarget {
    /// The CLI that answers for this link.
    var tool: ExternalTool {
        switch self {
        case .gitlabMR: .glab
        case .jira: .jira
        case .githubPR: .gh
        }
    }
}

public enum ToolCheck {
    /// Where the tool is installed, checked on disk: no shell, so no access to a profile kept in Documents.
    public static func locate(_ tool: ExternalTool, fileManager: FileManager = .default) -> String? {
        AppToolRunner.locate(tool.rawValue, fileManager: fileManager)?.path
    }

    public static func homebrew(fileManager: FileManager = .default) -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { fileManager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The exact command shown to the user before anything runs.
    public static func installArguments(for tools: [ExternalTool]) -> [String] {
        ["install"] + tools.map(\.formula)
    }

    /// Runs `brew install` for the missing tools and returns its last output lines, for the user to read.
    public static func install(_ tools: [ExternalTool], brew: URL) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = brew
            process.arguments = installArguments(for: tools)
            var environment = ProcessInfo.processInfo.environment
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["NONINTERACTIVE"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let tail = output.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
            guard process.terminationStatus == 0 else { throw LiveError.failed(tool: "brew", message: tail) }
            return tail
        }.value
    }
}
