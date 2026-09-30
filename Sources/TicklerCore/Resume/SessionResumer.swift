import Foundation

public enum ResumeOutcome: Equatable, Sendable {
    case focused(paneId: String)
    case spawned(paneId: String)
    case startedWindow
}

public enum ResumeError: Error, Equatable, CustomStringConvertible {
    case invalidSessionId(String)
    case noFolder
    case folderMissing(String)
    case notInWezTerm(pid: Int32)
    case terminal(String)

    public var description: String {
        switch self {
        case let .invalidSessionId(id): "not a Claude session id: \(id)"
        case .noFolder: "the session is not running and the reminder has no folder to resume it in"
        case let .folderMissing(path): "folder \(path) does not exist"
        case let .notInWezTerm(pid): "the session runs as pid \(pid) but not in a WezTerm pane"
        case let .terminal(message): message
        }
    }
}

/// Brings a Claude Code session back: focus its pane if it still runs, otherwise reopen it with `claude --resume`.
public struct SessionResumer: Sendable {
    let registry: SessionRegistry
    let inspector: ProcessInspecting
    let driver: TerminalDriver

    public init(
        registry: SessionRegistry = SessionRegistry(),
        inspector: ProcessInspecting = SystemProcessInspector(),
        driver: TerminalDriver
    ) {
        self.registry = registry
        self.inspector = inspector
        self.driver = driver
    }

    public func resume(sessionId: String, fallbackCwd: String?) throws -> ResumeOutcome {
        guard sessionId.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil else {
            throw ResumeError.invalidSessionId(sessionId)
        }
        if let pid = livePid(of: sessionId) {
            guard driver.isRunning(), let tty = inspector.ttyPath(of: pid), let pane = try driver.paneId(forTTY: tty) else {
                throw ResumeError.notInWezTerm(pid: pid)
            }
            try driver.activate(paneId: pane)
            driver.bringToFront()
            return .focused(paneId: pane)
        }

        guard let folder = fallbackCwd, !folder.isEmpty else { throw ResumeError.noFolder }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ResumeError.folderMissing(folder)
        }
        let command = Self.resumeCommand(sessionId: sessionId)
        guard driver.isRunning() else {
            try driver.start(cwd: folder, command: command)
            return .startedWindow
        }
        let pane = try driver.spawn(cwd: folder, command: command)
        try driver.activate(paneId: pane)
        driver.bringToFront()
        return .spawned(paneId: pane)
    }

    /// The registry covers sessions started normally; a session resumed from another one has no file, so match its command line.
    func livePid(of sessionId: String) -> Int32? {
        if let record = registry.records(for: sessionId).first(where: isLive) {
            return record.pid
        }
        return inspector.pid(runningResumeOf: sessionId)
    }

    /// Registry files outlive their process and pids get reused: the pid must still be a Claude process.
    private func isLive(_ record: SessionRegistry.Record) -> Bool {
        inspector.isAlive(record.pid) && inspector.commandLine(of: record.pid).map(SystemProcessInspector.isClaude) == true
    }

    /// Which of `sessionIds` still run, reading the registry once and the process table once.
    public func runningSessions(_ sessionIds: Set<String>) -> Set<String> {
        guard !sessionIds.isEmpty else { return [] }
        let live = Set(registry.allRecords().filter { sessionIds.contains($0.sessionId) && isLive($0) }.map(\.sessionId))
        let resumed = Set(inspector.resumedSessions().keys)
        return sessionIds.filter { live.contains($0) || resumed.contains($0) }
    }

    /// Scrubs the calling session's markers: an inherited CLAUDE_CODE_CHILD_SESSION turns transcript saving off.
    /// Login and interactive shell, so PATH and the environment match a normal terminal tab.
    public static func resumeCommand(sessionId: String) -> [String] {
        let scrubbed = [
            "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_PID", "CLAUDE_EFFORT",
        ]
        return ["env"] + scrubbed.flatMap { ["-u", $0] } + ["zsh", "-lic", "claude --resume \(sessionId)"]
    }
}

/// `~/.claude/sessions/<pid>.json`, one file per live Claude Code session; a file can outlive its process.
public struct SessionRegistry: Sendable {
    public struct Record: Decodable, Equatable, Sendable {
        public let sessionId: String
        public let pid: Int32
        public let cwd: String?
    }

    let directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")) {
        self.directory = directory
    }

    public func records(for sessionId: String) -> [Record] {
        allRecords().filter { $0.sessionId == sessionId }
    }

    public func allRecords() -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Record.self, from: Data(contentsOf: $0)) }
    }
}
