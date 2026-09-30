import Foundation

/// Runs an AppleScript with arguments. Values reach the script through `argv`, never through its source text.
public protocol ScriptRunning: Sendable {
    func run(_ source: String, arguments: [String]) throws -> String
}

public struct OSAScriptRunner: ScriptRunning {
    public init() {}

    public func run(_ source: String, arguments: [String]) throws -> String {
        try WezTermDriver.execute(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source] + arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Quotes each word for a POSIX shell, so a command can be typed into the user's shell as one line.
public func shellJoin(_ words: [String]) -> String {
    words.map { word in
        word.wholeMatch(of: /[A-Za-z0-9_\/.:=@%+-]+/) != nil ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }.joined(separator: " ")
}

/// A terminal scripted through its AppleScript dictionary: iTerm2 and Ghostty.
/// New tabs start the resume command in the user's own shell, with `cd` first, as if typed.
public struct AppleScriptTerminalDriver: TerminalDriver {
    public let bundleIdentifier: String
    let findScript: String
    let activateScript: String
    let spawnScript: String
    let runner: ScriptRunning

    public func isRunning() -> Bool {
        (try? runner.run(
            #"on run argv\#nreturn application id (item 1 of argv) is running\#nend run"#,
            arguments: [bundleIdentifier]
        )) == "true"
    }

    public func paneId(forTTY tty: String) throws -> String? {
        let id = try runner.run(findScript, arguments: [tty])
        return id.isEmpty ? nil : id
    }

    public func activate(paneId: String) throws {
        _ = try runner.run(activateScript, arguments: [paneId])
    }

    public func spawn(cwd: String, command: [String]) throws -> String {
        try runner.run(spawnScript, arguments: [cwd, "cd " + shellJoin([cwd]) + " && " + shellJoin(command)])
    }

    public func start(cwd: String, command: [String]) throws {
        _ = try spawn(cwd: cwd, command: command)
    }

    /// The scripts above already bring the app forward.
    public func bringToFront() {}

    public func killPane(_: String) throws {}

    public static func iTerm(runner: ScriptRunning = OSAScriptRunner()) -> AppleScriptTerminalDriver {
        AppleScriptTerminalDriver(
            bundleIdentifier: "com.googlecode.iterm2",
            findScript: """
            on run argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is (item 1 of argv) then return id of s
                    end repeat
                  end repeat
                end repeat
              end tell
              return ""
            end run
            """,
            activateScript: """
            on run argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if id of s is (item 1 of argv) then
                        select w
                        select t
                        select s
                        activate
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              error "iTerm2 session not found"
            end run
            """,
            spawnScript: """
            on run argv
              tell application id "com.googlecode.iterm2"
                activate
                if (count of windows) is 0 then
                  set w to (create window with default profile)
                else
                  set w to current window
                  tell w to create tab with default profile
                end if
                set s to current session of current tab of w
                tell s to write text (item 2 of argv)
                return id of s
              end tell
            end run
            """,
            runner: runner
        )
    }

    public static func ghostty(runner: ScriptRunning = OSAScriptRunner()) -> AppleScriptTerminalDriver {
        AppleScriptTerminalDriver(
            bundleIdentifier: "com.mitchellh.ghostty",
            findScript: """
            on run argv
              tell application id "com.mitchellh.ghostty"
                repeat with t in terminals
                  if tty of t is (item 1 of argv) then return id of t
                end repeat
              end tell
              return ""
            end run
            """,
            activateScript: """
            on run argv
              tell application id "com.mitchellh.ghostty"
                set t to first terminal whose id is (item 1 of argv)
                focus t
                activate
              end tell
              return "ok"
            end run
            """,
            spawnScript: """
            on run argv
              tell application id "com.mitchellh.ghostty"
                activate
                set cfg to new surface configuration
                set initial working directory of cfg to (item 1 of argv)
                set initial input of cfg to (item 2 of argv) & linefeed
                if (count of windows) is 0 then
                  set w to new window with configuration cfg
                  set t to focused terminal of selected tab of w
                else
                  set tb to new tab in front window with configuration cfg
                  set t to focused terminal of tb
                end if
                return id of t
              end tell
            end run
            """,
            runner: runner
        )
    }
}

/// Every supported terminal at once: a running session is found in whichever terminal holds it,
/// a new one opens in the preferred terminal. Pane ids carry their terminal: `wezterm:3`, `iterm:<uuid>`.
public struct CompositeTerminalDriver: TerminalDriver {
    public struct Member: Sendable {
        public let name: String
        public let driver: TerminalDriver
        public let installed: Bool

        public init(name: String, driver: TerminalDriver, installed: Bool) {
            self.name = name
            self.driver = driver
            self.installed = installed
        }
    }

    let members: [Member]

    /// `members` in order of preference.
    public init(members: [Member]) {
        self.members = members
    }

    public func isRunning() -> Bool {
        members.contains { $0.driver.isRunning() }
    }

    public func paneId(forTTY tty: String) throws -> String? {
        for member in members where member.driver.isRunning() {
            if let pane = try? member.driver.paneId(forTTY: tty) {
                return "\(member.name):\(pane)"
            }
        }
        return nil
    }

    public func activate(paneId: String) throws {
        let (member, pane) = try resolve(paneId)
        try member.driver.activate(paneId: pane)
        member.driver.bringToFront()
    }

    /// The preferred terminal among the running ones, else the preferred installed one.
    public func spawn(cwd: String, command: [String]) throws -> String {
        guard let member = members.first(where: { $0.driver.isRunning() }) ?? members.first(where: \.installed) else {
            throw ResumeError.terminal("no supported terminal found (WezTerm, Ghostty or iTerm2)")
        }
        if member.driver.isRunning() {
            return try "\(member.name):" + member.driver.spawn(cwd: cwd, command: command)
        }
        try member.driver.start(cwd: cwd, command: command)
        return "\(member.name):"
    }

    public func start(cwd: String, command: [String]) throws {
        _ = try spawn(cwd: cwd, command: command)
    }

    public func bringToFront() {}

    public func killPane(_ paneId: String) throws {
        let (member, pane) = try resolve(paneId)
        try member.driver.killPane(pane)
    }

    private func resolve(_ paneId: String) throws -> (Member, String) {
        guard let colon = paneId.firstIndex(of: ":"),
              let member = members.first(where: { $0.name == paneId[..<colon] })
        else {
            throw ResumeError.terminal("unknown pane \(paneId)")
        }
        return (member, String(paneId[paneId.index(after: colon)...]))
    }
}

public enum TerminalChoice: String, CaseIterable, Sendable {
    case auto
    case wezterm
    case ghostty
    case iterm

    /// What Settings offers: Automatic, then the terminals found on this Mac.
    public static func available(weztermPath: String? = nil, fileManager: FileManager = .default) -> [TerminalChoice] {
        [.auto] + [.wezterm, .ghostty, .iterm].filter { $0.isInstalled(weztermPath: weztermPath, fileManager: fileManager) }
    }

    public func isInstalled(weztermPath: String? = nil, fileManager: FileManager = .default) -> Bool {
        switch self {
        case .auto: true
        case .wezterm: WezTermDriver.resolveBinary(configured: weztermPath, fileManager: fileManager) != nil
        case .ghostty: Self.appInstalled("Ghostty.app", fileManager: fileManager)
        case .iterm: Self.appInstalled("iTerm.app", fileManager: fileManager)
        }
    }

    static func appInstalled(_ bundle: String, fileManager: FileManager) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(bundle)").path
        return fileManager.fileExists(atPath: "/Applications/\(bundle)") || fileManager.fileExists(atPath: home)
    }

    /// The drivers in preference order: the chosen terminal first, then WezTerm, Ghostty, iTerm2.
    public func driver(weztermPath: String? = nil, fileManager: FileManager = .default) -> CompositeTerminalDriver {
        let wezterm = WezTermDriver.resolveBinary(configured: weztermPath, fileManager: fileManager)
        var members = [
            CompositeTerminalDriver.Member(
                name: "wezterm",
                driver: WezTermDriver(binary: wezterm ?? URL(fileURLWithPath: "/usr/bin/false")),
                installed: wezterm != nil
            ),
            CompositeTerminalDriver.Member(
                name: "ghostty", driver: AppleScriptTerminalDriver.ghostty(),
                installed: TerminalChoice.ghostty.isInstalled(fileManager: fileManager)
            ),
            CompositeTerminalDriver.Member(
                name: "iterm", driver: AppleScriptTerminalDriver.iTerm(),
                installed: TerminalChoice.iterm.isInstalled(fileManager: fileManager)
            ),
        ]
        if let index = members.firstIndex(where: { $0.name == rawValue }) {
            members.insert(members.remove(at: index), at: 0)
        }
        return CompositeTerminalDriver(members: members)
    }
}
