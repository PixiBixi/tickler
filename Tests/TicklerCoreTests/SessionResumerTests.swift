import Foundation
import Testing
@testable import TicklerCore

private let sessionId = "5b26f281-1806-47aa-8842-0e264f7b9d35"

final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var alive: Set<Int32> = []
    var ttys: [Int32: String] = [:]
    var resumePid: Int32?
    var commandLines: [Int32: [String]] = [:]

    func isAlive(_ pid: Int32) -> Bool {
        alive.contains(pid)
    }

    func ttyPath(of pid: Int32) -> String? {
        ttys[pid]
    }

    /// Alive pids look like Claude unless a test says otherwise.
    func commandLine(of pid: Int32) -> [String]? {
        commandLines[pid] ?? (alive.contains(pid) ? ["claude"] : nil)
    }

    func resumedSessions() -> [String: Int32] {
        resumePid.map { [sessionId: $0] } ?? [:]
    }
}

final class FakeDriver: TerminalDriver, @unchecked Sendable {
    var running = true
    var panes: [String: String] = [:]
    var calls: [String] = []
    var canType = true
    var lastCommand: [String] = []

    func isRunning() -> Bool {
        running
    }

    func paneId(forTTY tty: String) throws -> String? {
        panes[tty]
    }

    func activate(paneId: String) throws {
        calls.append("activate \(paneId)")
    }

    func spawn(cwd: String, command: [String]) throws -> String {
        lastCommand = command
        calls.append("spawn \(cwd)")
        return "42"
    }

    func start(cwd: String, command _: [String]) throws -> String? {
        calls.append("start \(cwd)")
        return nil
    }

    func bringToFront() {
        calls.append("front")
    }

    func killPane(_ paneId: String) throws {
        calls.append("kill \(paneId)")
    }

    func type(_ text: String, intoPane paneId: String) throws -> Bool {
        guard canType else { return false }
        calls.append("type \(paneId) \(text)")
        return true
    }
}

final class FakeOpener: URLOpening, @unchecked Sendable {
    var opened: [URL] = []

    func open(_ url: URL) throws {
        opened.append(url)
    }
}

struct SessionResumerTests {
    let registryDir: URL
    let desktopDir: URL
    let folder: String
    let opener = FakeOpener()

    init() throws {
        registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        desktopDir = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        folder = FileManager.default.temporaryDirectory.path
    }

    /// Same layout as the app: `<account>/<org>/local_<id>.json`.
    func writeDesktopSession(_ desktopId: String, wrapping cliId: String = sessionId) throws {
        let dir = desktopDir.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"sessionId":"\#(desktopId)","cliSessionId":"\#(cliId)","cwd":"/tmp","isArchived":false}"#
        try json.write(to: dir.appendingPathComponent("local_file-\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    }

    func writeRecord(pid: Int32, cwd: String = "/tmp", id: String = sessionId) throws {
        let json = #"{"sessionId":"\#(id)","pid":\#(pid),"cwd":"\#(cwd)","status":"idle"}"#
        try json.write(to: registryDir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    func resumer(_ inspector: FakeInspector, _ driver: FakeDriver) -> SessionResumer {
        SessionResumer(
            registry: SessionRegistry(directory: registryDir),
            inspector: inspector,
            driver: driver,
            desktopSessions: DesktopSessionIndex(directory: desktopDir),
            opener: opener
        )
    }

    @Test func runningDesktopSessionOpensInTheApp() throws {
        try writeDesktopSession("local_f57a972d-21e4-4355-96c9-f6b130cc8418")
        let inspector = FakeInspector()
        inspector.resumePid = 300
        let driver = FakeDriver()

        let outcome = try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: folder, prompt: "check it")
        #expect(outcome == .openedInDesktop)
        #expect(opener.opened.map(\.absoluteString) == ["claude://code/continue?session=local_f57a972d-21e4-4355-96c9-f6b130cc8418"])
        #expect(driver.calls.isEmpty)
    }

    @Test func endedDesktopSessionOpensInTheAppNotInATerminal() throws {
        try writeDesktopSession("local_abc")
        let driver = FakeDriver()
        #expect(try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: folder) == .openedInDesktop)
        #expect(driver.calls.isEmpty)
    }

    @Test func terminalPaneWinsOverTheDesktopApp() throws {
        try writeRecord(pid: 100)
        try writeDesktopSession("local_abc")
        let inspector = FakeInspector()
        inspector.alive = [100]
        inspector.ttys = [100: "/dev/ttys003"]
        let driver = FakeDriver()
        driver.panes = ["/dev/ttys003": "3"]
        #expect(try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: nil) == .focused(paneId: "3"))
        #expect(opener.opened.isEmpty)
    }

    @Test func ignoresOtherAndMalformedDesktopSessions() throws {
        try writeDesktopSession("local_other", wrapping: "11111111-2222-3333-4444-555555555555")
        try writeDesktopSession("local_../evil")
        try writeDesktopSession("session_abc")
        let driver = FakeDriver()
        #expect(try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: folder) == .spawned(paneId: "42"))
        #expect(opener.opened.isEmpty)
    }

    @Test func focusesTheRunningPane() throws {
        try writeRecord(pid: 100)
        let inspector = FakeInspector()
        inspector.alive = [100]
        inspector.ttys = [100: "/dev/ttys003"]
        let driver = FakeDriver()
        driver.panes = ["/dev/ttys003": "3"]

        let outcome = try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: nil)
        #expect(outcome == .focused(paneId: "3"))
        #expect(driver.calls == ["activate 3", "front"])
    }

    @Test func reusedPidIsNotTheSession() throws {
        try writeRecord(pid: 100)
        let inspector = FakeInspector()
        inspector.alive = [100]
        inspector.commandLines = [100: ["/usr/bin/vim"]]
        let driver = FakeDriver()
        #expect(try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: folder) == .spawned(paneId: "42"))
        #expect(resumer(inspector, driver).runningSessions([sessionId]).isEmpty)
    }

    @Test func runningSessionsChecksEachIdOnce() throws {
        try writeRecord(pid: 100)
        let inspector = FakeInspector()
        inspector.alive = [100]
        let other = "11111111-2222-3333-4444-555555555555"
        #expect(resumer(inspector, FakeDriver()).runningSessions([sessionId, other]) == [sessionId])
    }

    @Test func staleRecordSpawnsInTheReminderFolder() throws {
        try writeRecord(pid: 100)
        let driver = FakeDriver()
        let outcome = try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: folder)
        #expect(outcome == .spawned(paneId: "42"))
        #expect(driver.calls == ["spawn \(folder)", "activate 42", "front"])
    }

    @Test func findsResumedSessionsWithoutRecord() throws {
        let inspector = FakeInspector()
        inspector.resumePid = 200
        inspector.ttys = [200: "/dev/ttys009"]
        let driver = FakeDriver()
        driver.panes = ["/dev/ttys009": "9"]
        #expect(try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: nil) == .focused(paneId: "9"))
    }

    @Test func startsAWindowWhenWezTermIsNotRunning() throws {
        let driver = FakeDriver()
        driver.running = false
        let outcome = try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: folder)
        #expect(outcome == .startedWindow)
        #expect(driver.calls == ["start \(folder)"])
    }

    @Test func errors() throws {
        let driver = FakeDriver()
        #expect(throws: ResumeError.noFolder) {
            try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: nil)
        }
        #expect(throws: ResumeError.folderMissing("/nope/nowhere")) {
            try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: "/nope/nowhere")
        }
        #expect(throws: ResumeError.invalidSessionId("abc")) {
            try resumer(FakeInspector(), driver).resume(sessionId: "abc", fallbackCwd: folder)
        }
        let inspector = FakeInspector()
        inspector.resumePid = 300
        #expect(throws: ResumeError.notInWezTerm(pid: 300)) {
            try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: folder)
        }
    }

    @Test func runningSessionGetsThePromptTypedNotSent() throws {
        try writeRecord(pid: 100)
        let inspector = FakeInspector()
        inspector.alive = [100]
        inspector.ttys = [100: "/dev/ttys003"]
        let driver = FakeDriver()
        driver.panes = ["/dev/ttys003": "3"]

        #expect(try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: nil, prompt: "compare ws-ports")
            == .focused(paneId: "3", typedPrompt: true))
        #expect(driver.calls.contains("type 3 compare ws-ports"))
        driver.canType = false
        #expect(try resumer(inspector, driver).resume(sessionId: sessionId, fallbackCwd: nil, prompt: "x") == .focused(paneId: "3"))
    }

    @Test func reopenedSessionGetsThePromptAsItsFirstMessage() throws {
        let driver = FakeDriver()
        _ = try resumer(FakeInspector(), driver).resume(sessionId: sessionId, fallbackCwd: folder, prompt: "it's $(rm -rf ~)")
        #expect(driver.lastCommand.last == #"claude --resume \#(sessionId) -- 'it'\''s $(rm -rf ~)'"#)
    }

    @Test func resumeCommandScrubsTheCallingSession() {
        let command = SessionResumer.resumeCommand(sessionId: sessionId)
        #expect(command.first == "env")
        #expect(command.contains("CLAUDECODE"))
        #expect(command.contains("CLAUDE_CODE_SESSION_ID"))
        #expect(command.suffix(3) == ["zsh", "-lic", "claude --resume \(sessionId)"])
    }

    @Test func wezTermListDecoding() throws {
        let json = #"[{"pane_id":3,"tty_name":"/dev/ttys003","cwd":"file:///x"},{"pane_id":7,"tty_name":null}]"#
        let panes = try WezTermDriver.decodePanes(Data(json.utf8))
        #expect(panes == ["/dev/ttys003": "3"])
    }

    @Test func wezTermAnchorPrefersAnActivePane() throws {
        let json = #"[{"pane_id":3,"is_active":false},{"pane_id":7,"is_active":true}]"#
        #expect(try WezTermDriver.anchorPane(Data(json.utf8)) == "7")
        #expect(try WezTermDriver.anchorPane(Data(#"[{"pane_id":3}]"#.utf8)) == "3")
        #expect(try WezTermDriver.anchorPane(Data("[]".utf8)) == nil)
    }

    @Test func wezTermAnchorPrefersTheFocusedPane() throws {
        let json = #"[{"pane_id":3,"is_active":true},{"pane_id":7,"is_active":true}]"#
        #expect(try WezTermDriver.anchorPane(Data(json.utf8), focused: 7) == "7")
        #expect(try WezTermDriver.anchorPane(Data(json.utf8), focused: 42) == "3")
    }

    @Test func wezTermFocusedPaneDecoding() {
        let json = #"[{"workspace":"default","focused_pane_id":null},{"workspace":"default","focused_pane_id":91}]"#
        #expect(WezTermDriver.focusedPane(Data(json.utf8)) == 91)
        #expect(WezTermDriver.focusedPane(Data("[]".utf8)) == nil)
        #expect(WezTermDriver.focusedPane(Data("not json".utf8)) == nil)
    }
}

/// A fake `wezterm` answering per socket: `cli list` prints `<socket name>.json` or fails, `cli spawn` prints 42.
struct FakeWezTerm {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wezterm-\(UUID().uuidString)")
    var binary: URL {
        directory.appendingPathComponent("wezterm")
    }

    var log: URL {
        directory.appendingPathComponent("calls.log")
    }

    init(instances: [Int32: String?]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        sock=$(basename "${WEZTERM_UNIX_SOCKET:-none}")
        echo "$sock $*" >> "\(log.path)"
        case "$2" in
          list) cat "\(directory.path)/$sock.json" 2>/dev/null || exit 1 ;;
          spawn) echo 42 ;;
        esac
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        for (pid, panes) in instances {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("gui-sock-\(pid)").path, contents: nil)
            try panes?.write(to: directory.appendingPathComponent("gui-sock-\(pid).json"), atomically: true, encoding: .utf8)
        }
    }

    func driver(alive: Set<Int32>) -> WezTermDriver {
        WezTermDriver(binary: binary, socketDirectory: directory, isAlive: { alive.contains($0) })
    }

    func calls() throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

struct WezTermSocketTests {
    @Test func skipsTheSocketOfACrashedInstance() throws {
        let fake = try FakeWezTerm(instances: [100: nil, 200: #"[{"pane_id":5,"is_active":true}]"#])
        let driver = fake.driver(alive: [200])
        #expect(driver.isRunning())
        #expect(try driver.spawn(cwd: "/x", command: ["claude"]) == "42")
        #expect(try fake.calls().allSatisfy { $0.hasPrefix("gui-sock-200 ") })
        #expect(try fake.calls().last == "gui-sock-200 cli spawn --pane-id 5 --cwd /x -- claude")
    }

    @Test func findsASessionInASecondInstanceAndActivatesItThere() throws {
        let fake = try FakeWezTerm(instances: [
            100: #"[{"pane_id":5,"tty_name":"/dev/ttys001"}]"#,
            200: #"[{"pane_id":5,"tty_name":"/dev/ttys000"}]"#,
        ])
        let driver = fake.driver(alive: [100, 200])
        #expect(try driver.paneId(forTTY: "/dev/ttys000") == "5")
        try driver.activate(paneId: "5")
        #expect(try fake.calls().last == "gui-sock-200 cli activate-pane --pane-id 5")
    }

    @Test func notRunningWhenEverySocketIsDead() throws {
        let fake = try FakeWezTerm(instances: [100: #"[{"pane_id":5}]"#])
        #expect(!fake.driver(alive: []).isRunning())
    }
}

struct ProcessArgumentsTests {
    @Test func parsesKernProcArgs2Layout() {
        var buffer = Data()
        var argc: Int32 = 3
        buffer.append(Data(bytes: &argc, count: 4))
        buffer.append(Data("/opt/homebrew/bin/claude\0\0\0".utf8))
        buffer.append(Data("claude\0--resume\0\(sessionId)\0HOME=/Users/x\0".utf8))
        #expect(SystemProcessInspector.arguments(fromProcArgs: buffer) == ["claude", "--resume", sessionId])
    }

    @Test func matchesOtherResumeForms() {
        #expect(SystemProcessInspector.resumedSession(in: ["claude", "-r", sessionId]) == sessionId)
        #expect(SystemProcessInspector.resumedSession(in: ["claude", "--resume=\(sessionId)"]) == sessionId)
        #expect(SystemProcessInspector.resumedSession(in: [
            "node",
            "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "--resume",
            sessionId,
        ]) == sessionId)
        #expect(SystemProcessInspector.resumedSession(in: ["claude"]) == nil)
    }

    @Test func matchesResumeInvocations() {
        #expect(SystemProcessInspector.isResume(of: sessionId, arguments: ["claude", "--resume", sessionId]))
        #expect(SystemProcessInspector.isResume(of: sessionId, arguments: ["/usr/local/bin/claude", "--resume", sessionId, "-c"]))
        #expect(!SystemProcessInspector.isResume(of: sessionId, arguments: ["vim", "--resume", sessionId]))
        #expect(!SystemProcessInspector.isResume(of: sessionId, arguments: ["claude", sessionId]))
    }
}
