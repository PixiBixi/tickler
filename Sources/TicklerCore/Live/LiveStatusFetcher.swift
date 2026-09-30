import Foundation

public protocol CommandRunning: Sendable {
    /// Runs `tool` with `arguments` and returns its standard output.
    func run(_ tool: String, _ arguments: [String]) async throws -> Data
}

/// Runs tools through the user's login shell: an app started from Finder has neither the shell PATH
/// nor tokens such as JIRA_API_TOKEN. Arguments go in as positional parameters, never into the script text.
public struct LoginShellRunner: CommandRunning {
    let shell: String

    public init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        self.shell = shell
    }

    static func command(shell: String, tool: String, arguments: [String]) -> [String] {
        [shell, "-lic", #"exec "$0" "$@""#, tool] + arguments
    }

    public func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        let command = Self.command(shell: shell, tool: tool, arguments: arguments)
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: errors, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if process.terminationStatus == 127 || message.contains("command not found") {
                throw LiveError.toolMissing(tool)
            }
            guard process.terminationStatus == 0 else {
                throw LiveError.failed(tool: tool, message: message.trimmingCharacters(in: .whitespaces))
            }
            return output
        }.value
    }
}

/// Asks glab, jira and gh about a link.
public struct LiveStatusFetcher: Sendable {
    let runner: CommandRunning

    public init(runner: CommandRunning = LoginShellRunner()) {
        self.runner = runner
    }

    public func fetch(_ target: LiveTarget) async throws -> LiveStatus {
        switch target {
        case let .gitlabMR(host, project, iid):
            let path = Self.mergeRequestPath(project: project, iid: iid)
            async let request = runner.run("glab", ["api", "--hostname", host, path])
            async let approvals = runner.run("glab", ["api", "--hostname", host, path + "/approvals"])
            return try await .mergeRequest(LiveStatusParser.mergeRequest(mr: request, approvals: approvals))
        case let .jira(key):
            return try await .ticket(LiveStatusParser.ticket(runner.run("jira", ["issue", "view", key, "--raw"])))
        case let .githubPR(owner, repo, number):
            let data = try await runner.run("gh", [
                "pr", "view", "https://github.com/\(owner)/\(repo)/pull/\(number)",
                "--json", "number,title,state,isDraft,reviewDecision,statusCheckRollup,url",
            ])
            return try .pullRequest(LiveStatusParser.pullRequest(data))
        }
    }

    public func approve(_ target: LiveTarget) async throws {
        guard case let .gitlabMR(host, project, iid) = target else { throw LiveError.unsupported }
        _ = try await runner.run(
            "glab",
            ["api", "--hostname", host, "-X", "POST", Self.mergeRequestPath(project: project, iid: iid) + "/approve"]
        )
    }

    static func mergeRequestPath(project: String, iid: Int) -> String {
        let encoded = project
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? project
        return "projects/\(encoded)/merge_requests/\(iid)"
    }
}

/// Runs tools with the caller's own environment: right for the CLI, which already runs in the user's shell.
public struct DirectRunner: CommandRunning {
    public init() {}

    public func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool] + arguments
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: errors, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if process.terminationStatus == 127 {
                throw LiveError.toolMissing(tool)
            }
            guard process.terminationStatus == 0 else {
                throw LiveError.failed(tool: tool, message: message.trimmingCharacters(in: .whitespaces))
            }
            return output
        }.value
    }
}

/// The app's runner: glab and gh straight from the usual install folders, with no shell, as their logins live in
/// ~/.config. jira goes through the login shell because JIRA_API_TOKEN usually exists only in the shell profile.
public struct AppToolRunner: CommandRunning {
    public static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    let shell: LoginShellRunner

    public init(shell: LoginShellRunner = LoginShellRunner()) {
        self.shell = shell
    }

    public static func needsShell(_ tool: String) -> Bool {
        tool == ExternalTool.jira.rawValue
    }

    public static func locate(_ tool: String, fileManager: FileManager = .default) -> URL? {
        searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        if Self.needsShell(tool) {
            return try await shell.run(tool, arguments)
        }
        guard let binary = Self.locate(tool) else { throw LiveError.toolMissing(tool) }
        return try await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Self.searchPath.joined(separator: ":")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                throw LiveError.failed(tool: tool, message: message.trimmingCharacters(in: .whitespaces))
            }
            return output
        }.value
    }
}
