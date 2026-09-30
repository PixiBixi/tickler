import Foundation

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
}

/// Drives WezTerm through its official `wezterm cli`, called by absolute path: an app started from Finder has no shell PATH.
public struct WezTermDriver: TerminalDriver {
    public let binary: URL

    public init(binary: URL) {
        self.binary = binary
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

    public func isRunning() -> Bool {
        (try? run(["cli", "list"])) != nil
    }

    public func paneId(forTTY tty: String) throws -> String? {
        try Self.decodePanes(Data(run(["cli", "list", "--format", "json"]).utf8))[tty]
    }

    public func activate(paneId: String) throws {
        _ = try run(["cli", "activate-pane", "--pane-id", paneId])
    }

    public func spawn(cwd: String, command: [String]) throws -> String {
        try run(["cli", "spawn", "--cwd", cwd, "--"] + command).trimmingCharacters(in: .whitespacesAndNewlines)
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
        _ = try run(["cli", "kill-pane", "--pane-id", paneId])
    }

    /// tty path to pane id, from `wezterm cli list --format json`.
    static func decodePanes(_ data: Data) throws -> [String: String] {
        struct Pane: Decodable {
            let paneId: Int
            let ttyName: String?
            enum CodingKeys: String, CodingKey {
                case paneId = "pane_id"
                case ttyName = "tty_name"
            }
        }
        let panes = try JSONDecoder().decode([Pane].self, from: data)
        return Dictionary(
            panes.compactMap { pane in pane.ttyName.map { ($0, String(pane.paneId)) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func run(_ arguments: [String]) throws -> String {
        try Self.execute(binary, arguments)
    }

    static func execute(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw ResumeError.terminal("cannot run \(executable.path): \(error.localizedDescription)") }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResumeError.terminal("\(executable.lastPathComponent) \(arguments.prefix(2).joined(separator: " ")) failed: \(message)")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
