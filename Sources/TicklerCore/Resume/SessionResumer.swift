import Foundation

public enum ResumeOutcome: Equatable, Sendable {
    /// `typedPrompt`: the prompt was typed into the running session's input, not sent.
    case focused(paneId: String, typedPrompt: Bool = false)
    case spawned(paneId: String)
    case startedWindow
    /// The Claude desktop app owns the session; its link carries no prompt.
    case openedInDesktop
}

public enum ResumeError: Error, Equatable, CustomStringConvertible {
    case invalidSessionId(String)
    case noFolder
    case folderMissing(String)
    case notInWezTerm(pid: Int32)
    case terminal(String)
    case desktopApp(String)
    case freshNeedsPrompt
    case freshNeedsFolder

    public var description: String {
        switch self {
        case let .invalidSessionId(id): "not a Claude session id: \(id)"
        case .noFolder: "the session is not running and the reminder has no folder to resume it in"
        case let .folderMissing(path): "folder \(path) does not exist"
        case let .notInWezTerm(pid): "the session runs as pid \(pid) but not in a WezTerm pane"
        case let .terminal(message): message
        case let .desktopApp(message): "cannot open the session in the Claude desktop app: \(message)"
        case .freshNeedsPrompt: "a fresh session needs a resume prompt: set one with edit --prompt"
        case .freshNeedsFolder: "a fresh session needs a folder to start in: the reminder has none"
        }
    }
}

/// Brings a Claude Code session back: focus its pane if it still runs, hand a desktop app session to the app,
/// otherwise reopen it with `claude --resume`.
public struct SessionResumer: Sendable {
    let registry: SessionRegistry
    let inspector: ProcessInspecting
    let driver: TerminalDriver
    let desktopSessions: DesktopSessionIndex
    let opener: URLOpening

    public init(
        registry: SessionRegistry = SessionRegistry(),
        inspector: ProcessInspecting = SystemProcessInspector(),
        driver: TerminalDriver,
        desktopSessions: DesktopSessionIndex = DesktopSessionIndex(),
        opener: URLOpening = SystemURLOpener()
    ) {
        self.registry = registry
        self.inspector = inspector
        self.driver = driver
        self.desktopSessions = desktopSessions
        self.opener = opener
    }

    /// `prompt` becomes the first message of a reopened session; a running one gets it typed, never sent.
    public func resume(sessionId: String, fallbackCwd: String?, prompt: String? = nil) throws -> ResumeOutcome {
        guard sessionId.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil else {
            throw ResumeError.invalidSessionId(sessionId)
        }
        let pid = livePid(of: sessionId)
        if let pid, let pane = try terminalPane(of: pid) {
            try driver.activate(paneId: pane)
            driver.bringToFront()
            guard let prompt, !prompt.isEmpty else { return .focused(paneId: pane) }
            return .focused(paneId: pane, typedPrompt: (try? driver.type(prompt, intoPane: pane)) == true)
        }
        // A desktop session reopened with `claude --resume` in a terminal would fork its transcript away from the app.
        if let desktopId = desktopSessions.desktopSessionId(wrapping: sessionId),
           let url = DesktopSessionIndex.continueURL(desktopSessionId: desktopId)
        {
            do {
                try opener.open(url)
                return .openedInDesktop
            } catch {
                // The app can be gone while its session files remain: only an ended session can reopen in a terminal.
                if pid != nil {
                    throw error
                }
            }
        }
        if let pid {
            throw ResumeError.notInWezTerm(pid: pid)
        }

        guard let folder = fallbackCwd, !folder.isEmpty else { throw ResumeError.noFolder }
        return try open(Self.resumeCommand(sessionId: sessionId, prompt: prompt), in: folder)
    }

    /// Starts a new session in `cwd` with `prompt` as its first message: no running pane is focused, no desktop app involved.
    public func startFresh(cwd: String?, prompt: String?) throws -> ResumeOutcome {
        guard let folder = cwd, !folder.isEmpty else { throw ResumeError.freshNeedsFolder }
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResumeError.freshNeedsPrompt }
        return try open(Self.freshCommand(prompt: prompt), in: folder)
    }

    /// Runs `command` in `folder`, in a new tab or in a terminal started for it.
    private func open(_ command: [String], in folder: String) throws -> ResumeOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ResumeError.folderMissing(folder)
        }
        guard driver.isRunning() else {
            _ = try driver.start(cwd: folder, command: command)
            return .startedWindow
        }
        let pane = try driver.spawn(cwd: folder, command: command)
        try driver.activate(paneId: pane)
        driver.bringToFront()
        return .spawned(paneId: pane)
    }

    private func terminalPane(of pid: Int32) throws -> String? {
        guard driver.isRunning(), let tty = inspector.ttyPath(of: pid) else { return nil }
        return try driver.paneId(forTTY: tty)
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

    /// The calling session's markers, removed from the environment of any `claude` we start.
    public static let scrubbedVariables = [
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    /// Scrubs the calling session's markers: an inherited CLAUDE_CODE_CHILD_SESSION turns transcript saving off.
    /// Login and interactive shell, so PATH and the environment match a normal terminal tab.
    public static func resumeCommand(sessionId: String, prompt: String? = nil) -> [String] {
        let message = prompt.flatMap { $0.isEmpty ? nil : " -- " + shellJoin([$0]) } ?? ""
        return ["env"] + scrubbedVariables.flatMap { ["-u", $0] } + ["zsh", "-lic", "claude --resume \(sessionId)\(message)"]
    }

    /// A new session with `prompt` as its first message; same scrubbing and login shell as `resumeCommand`.
    public static func freshCommand(prompt: String) -> [String] {
        ["env"] + scrubbedVariables.flatMap { ["-u", $0] } + ["zsh", "-lic", "claude -- " + shellJoin([prompt])]
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
