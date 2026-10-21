import Foundation
import os

/// The terminal a session lives in. WezTerm is the only implementation; another terminal plugs in here.
public protocol TerminalDriver: Sendable {
    func isRunning() -> Bool
    func paneId(forTTY tty: String) throws -> String?
    func activate(paneId: String) throws
    /// New tab in the running terminal; returns its pane id.
    func spawn(cwd: String, command: [String]) throws -> String
    /// New window when the terminal is not running; returns the pane id when the terminal reports one.
    @discardableResult
    func start(cwd: String, command: [String]) throws -> String?
    func bringToFront()
    func killPane(_ paneId: String) throws
    /// Types `text` into a pane's input without pressing Return; false when the terminal cannot.
    func type(_ text: String, intoPane paneId: String) throws -> Bool
}

public extension TerminalDriver {
    func type(_: String, intoPane _: String) throws -> Bool {
        false
    }
}

/// Drives WezTerm through its official `wezterm cli`, called by absolute path: an app started from Finder has no shell PATH.
/// Every call names a live GUI socket: a crashed instance leaves its socket behind, `wezterm cli` may pick it and fail,
/// and a failed probe used to start a duplicate WezTerm whose panes the CLI then could not see.
public struct WezTermDriver: TerminalDriver {
    public let binary: URL
    let socketDirectory: URL
    let isAlive: @Sendable (Int32) -> Bool
    private let paneSockets = PaneSockets()

    public init(
        binary: URL,
        socketDirectory: URL = WezTermDriver.defaultSocketDirectory,
        isAlive: @escaping @Sendable (Int32) -> Bool = WezTermDriver.processExists
    ) {
        self.binary = binary
        self.socketDirectory = socketDirectory
        self.isAlive = isAlive
    }

    public static var defaultSocketDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wezterm")
    }

    public static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The configured path first, then Homebrew, then the binary inside the app bundle.
    public static func resolveBinary(configured: String? = nil, fileManager: FileManager = .default) -> URL? {
        let candidates = [
            configured,
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
        ]
        let found = candidates.compactMap(\.self).first { !$0.isEmpty && fileManager.isExecutableFile(atPath: $0) }
        return found.map(URL.init(fileURLWithPath:))
    }

    /// `gui-sock-<pid>` of the GUI instances still running, oldest first.
    static func liveSockets(in directory: URL, fileManager: FileManager = .default, isAlive: (Int32) -> Bool) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .compactMap { name -> (pid: Int32, url: URL)? in
                guard name.hasPrefix("gui-sock-"), let pid = Int32(name.dropFirst("gui-sock-".count)), isAlive(pid) else { return nil }
                return (pid, directory.appendingPathComponent(name))
            }
            .sorted { $0.pid < $1.pid }
            .map(\.url)
    }

    /// The live sockets, or nil alone when none is found: `wezterm cli` then picks one itself.
    private func instances() -> [URL?] {
        let sockets = Self.liveSockets(in: socketDirectory, isAlive: isAlive)
        return sockets.isEmpty ? [nil] : sockets
    }

    public func isRunning() -> Bool {
        instances().contains { (try? run(["cli", "list"], socket: $0)) != nil }
    }

    public func paneId(forTTY tty: String) throws -> String? {
        var lastError: Error?
        var answered = false
        for socket in instances() {
            do {
                let panes = try Self.decodePanes(Data(run(["cli", "list", "--format", "json"], socket: socket).utf8))
                answered = true
                if let pane = panes[tty] {
                    paneSockets.remember(pane, socket)
                    return pane
                }
            } catch {
                lastError = error
            }
        }
        if !answered, let lastError {
            throw lastError
        }
        return nil
    }

    public func activate(paneId: String) throws {
        _ = try run(["cli", "activate-pane", "--pane-id", paneId], socket: socket(of: paneId))
    }

    /// A new tab next to an existing pane of the oldest instance: without `--pane-id`, an app launched outside
    /// WezTerm has no WEZTERM_PANE and `cli spawn` cannot guess a window.
    public func spawn(cwd: String, command: [String]) throws -> String {
        let sockets = instances()
        for socket in sockets {
            let clients = try? run(["cli", "list-clients", "--format", "json"], socket: socket)
            let focused = clients.flatMap { Self.focusedPane(Data($0.utf8)) }
            guard let output = try? run(["cli", "list", "--format", "json"], socket: socket),
                  let anchor = try Self.anchorPane(Data(output.utf8), focused: focused)
            else { continue }
            return try spawn(["--pane-id", anchor], cwd: cwd, command: command, socket: socket)
        }
        return try spawn(["--new-window"], cwd: cwd, command: command, socket: sockets.first.flatMap(\.self))
    }

    private func spawn(_ target: [String], cwd: String, command: [String], socket: URL?) throws -> String {
        let pane = try run(["cli", "spawn"] + target + ["--cwd", cwd, "--"] + command, socket: socket)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        paneSockets.remember(pane, socket)
        return pane
    }

    public func start(cwd: String, command: [String]) throws -> String? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["start", "--cwd", cwd, "--"] + command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ResumeError.terminal("cannot start WezTerm: \(error.localizedDescription)") }
        return nil
    }

    public func bringToFront() {
        _ = try? Self.execute(URL(fileURLWithPath: "/usr/bin/open"), ["-a", "WezTerm"])
    }

    public func killPane(_ paneId: String) throws {
        _ = try run(["cli", "kill-pane", "--pane-id", paneId], socket: socket(of: paneId))
    }

    public func type(_ text: String, intoPane paneId: String) throws -> Bool {
        _ = try run(["cli", "send-text", "--pane-id", paneId, "--", text], socket: socket(of: paneId))
        return true
    }

    private struct Pane: Decodable {
        let paneId: Int
        let ttyName: String?
        let isActive: Bool?
        enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case ttyName = "tty_name"
            case isActive = "is_active"
        }
    }

    private struct Client: Decodable {
        let focusedPaneId: Int?
        enum CodingKeys: String, CodingKey {
            case focusedPaneId = "focused_pane_id"
        }
    }

    /// The pane focused in the GUI, from `wezterm cli list-clients --format json`; nil when unknown.
    static func focusedPane(_ data: Data) -> Int? {
        let clients = (try? JSONDecoder().decode([Client].self, from: data)) ?? []
        return clients.lazy.compactMap(\.focusedPaneId).first
    }

    /// The pane a new tab attaches to: the focused one, else an active one, nil when WezTerm has no pane.
    /// `is_active` is per tab, so it alone lands every new tab in the first window, not the one in use.
    static func anchorPane(_ data: Data, focused: Int? = nil) throws -> String? {
        let panes = try JSONDecoder().decode([Pane].self, from: data)
        let anchor = panes.first { $0.paneId == focused } ?? panes.first { $0.isActive == true } ?? panes.first
        return anchor.map { String($0.paneId) }
    }

    /// tty path to pane id, from `wezterm cli list --format json`.
    static func decodePanes(_ data: Data) throws -> [String: String] {
        let panes = try JSONDecoder().decode([Pane].self, from: data)
        return Dictionary(
            panes.compactMap { pane in pane.ttyName.map { ($0, String(pane.paneId)) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Pane ids are per instance: the socket that reported the pane, else the first instance that lists it.
    private func socket(of paneId: String) -> URL? {
        if let known = paneSockets.socket(for: paneId) {
            return known
        }
        for socket in instances() {
            guard let output = try? run(["cli", "list", "--format", "json"], socket: socket),
                  let panes = try? JSONDecoder().decode([Pane].self, from: Data(output.utf8))
            else { continue }
            if panes.contains(where: { String($0.paneId) == paneId }) {
                return socket
            }
        }
        return nil
    }

    private func run(_ arguments: [String], socket: URL?) throws -> String {
        try Self.execute(binary, arguments, environment: socket.map { ["WEZTERM_UNIX_SOCKET": $0.path] } ?? [:])
    }

    /// A frozen terminal or an automation prompt left unanswered must not hold the resume forever.
    static func execute(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let name = executable.lastPathComponent
        let result: ProcessOutcome
        do {
            result = try ProcessOutcome.run(process, tool: name, timeout: timeout)
        } catch let error as LiveError {
            throw ResumeError.terminal(error.description)
        } catch {
            throw ResumeError.terminal("cannot run \(executable.path): \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            let message = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResumeError.terminal("\(name) \(arguments.prefix(2).joined(separator: " ")) failed: \(message)")
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}

/// Which instance socket answered for a pane, kept for the next call on that pane.
final class PaneSockets: Sendable {
    private let state = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    func remember(_ paneId: String, _ socket: URL?) {
        guard let socket else { return }
        state.withLock { $0[paneId] = socket }
    }

    func socket(for paneId: String) -> URL? {
        state.withLock { $0[paneId] }
    }
}
