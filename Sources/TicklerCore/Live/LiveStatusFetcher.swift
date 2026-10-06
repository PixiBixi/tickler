import Foundation
import os

public protocol CommandRunning: Sendable {
    /// Runs `tool` with `arguments` and returns its standard output.
    func run(_ tool: String, _ arguments: [String]) async throws -> Data
}

/// Runs tools through the user's login shell: an app started from Finder has neither the shell PATH
/// nor tokens such as JIRA_API_TOKEN. Arguments go in as positional parameters, never into the script text.
public struct LoginShellRunner: CommandRunning {
    let shell: String
    let timeout: TimeInterval

    public init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", timeout: TimeInterval = 60) {
        self.shell = shell
        self.timeout = timeout
    }

    static func command(shell: String, tool: String, arguments: [String]) -> [String] {
        [shell, "-lic", #"exec "$0" "$@""#, tool] + arguments
    }

    public func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        let command = Self.command(shell: shell, tool: tool, arguments: arguments)
        let timeout = timeout
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            let result = try ProcessOutcome.run(process, tool: tool, timeout: timeout)
            let message = LiveError.failureMessage(result.errors)
            if result.status == 127 || message.contains("command not found") {
                throw LiveError.toolMissing(tool)
            }
            guard result.status == 0 else {
                throw LiveError.failed(tool: tool, message: message)
            }
            return result.output
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

    /// Merges with the MR's own options (squash, source branch removal), now or once the pipeline passes.
    public func merge(_ target: LiveTarget, whenPipelinePasses: Bool = false) async throws {
        guard case let .gitlabMR(host, project, iid) = target else { throw LiveError.unsupported }
        var arguments = ["api", "--hostname", host, "-X", "PUT", Self.mergeRequestPath(project: project, iid: iid) + "/merge"]
        if whenPipelinePasses {
            arguments += ["-f", "auto_merge=true"]
        }
        _ = try await runner.run("glab", arguments)
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
            let message = LiveError.failureMessage(errors)
            if process.terminationStatus == 127 {
                throw LiveError.toolMissing(tool)
            }
            guard process.terminationStatus == 0 else {
                throw LiveError.failed(tool: tool, message: message)
            }
            return output
        }.value
    }
}

/// The app's runner: tools straight from the usual install folders, with no shell, as glab and gh logins live in
/// ~/.config and jira finds its token in the keychain. jira retries through the login shell for a JIRA_API_TOKEN
/// exported by the shell profile; a profile that defers its loading (zsh-defer) never exports it there.
public struct AppToolRunner: CommandRunning {
    public static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    let shell: LoginShellRunner
    /// A tool still running after this long is stopped: one hung call must not hold back every other link.
    let timeout: TimeInterval
    /// Extra variables for one tool, read on every run: the app hands jira the token it keeps in its keychain.
    let environment: @Sendable (String) -> [String: String]

    public init(
        shell: LoginShellRunner = LoginShellRunner(),
        timeout: TimeInterval = 60,
        environment: @escaping @Sendable (String) -> [String: String] = { _ in [:] }
    ) {
        self.shell = shell
        self.timeout = timeout
        self.environment = environment
    }

    public static func needsShell(_ tool: String) -> Bool {
        tool == ExternalTool.jira.rawValue
    }

    public static func locate(_ tool: String, fileManager: FileManager = .default) -> URL? {
        searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        let extra = environment(tool)
        guard Self.needsShell(tool), extra["JIRA_API_TOKEN"] == nil else { return try await direct(tool, arguments, extra) }
        do {
            return try await direct(tool, arguments, extra)
        } catch LiveError.failed {
            return try await shell.run(tool, arguments)
        }
    }

    private func direct(_ tool: String, _ arguments: [String], _ extra: [String: String]) async throws -> Data {
        guard let binary = Self.locate(tool) else { throw LiveError.toolMissing(tool) }
        let timeout = timeout
        return try await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Self.searchPath.joined(separator: ":")
            environment.merge(extra) { _, new in new }
            process.environment = environment
            let result = try ProcessOutcome.run(process, tool: tool, timeout: timeout)
            guard result.status == 0 else {
                throw LiveError.failed(tool: tool, message: LiveError.failureMessage(result.errors))
            }
            return result.output
        }.value
    }
}

/// What a finished tool left: exit status and both outputs.
struct ProcessOutcome {
    let status: Int32
    let output: Data
    let errors: Data

    /// Blocking: drains both pipes while the tool runs, so a large output cannot fill a pipe and stall it.
    /// Past `timeout` the tool is terminated, killed if it ignores that, and the call throws `LiveError.timedOut`.
    static func run(_ process: Process, tool: String, timeout: TimeInterval) throws -> ProcessOutcome {
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let output = OSAllocatedUnfairLock(initialState: Data())
        let errors = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchGroup()
        for (handle, sink) in [(out.fileHandleForReading, output), (err.fileHandleForReading, errors)] {
            DispatchQueue.global().async(group: drained) {
                let data = handle.readDataToEndOfFile()
                sink.withLock { $0 = data }
            }
        }

        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success, drained.wait(timeout: deadline) == .success else {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
            throw LiveError.timedOut(tool: tool, seconds: timeout)
        }
        return ProcessOutcome(status: process.terminationStatus, output: output.withLock { $0 }, errors: errors.withLock { $0 })
    }
}
