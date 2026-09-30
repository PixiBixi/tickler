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

    func isRunning() -> Bool {
        running
    }

    func paneId(forTTY tty: String) throws -> String? {
        panes[tty]
    }

    func activate(paneId: String) throws {
        calls.append("activate \(paneId)")
    }

    func spawn(cwd: String, command _: [String]) throws -> String {
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
}

struct SessionResumerTests {
    let registryDir: URL
    let folder: String

    init() throws {
        registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        folder = FileManager.default.temporaryDirectory.path
    }

    func writeRecord(pid: Int32, cwd: String = "/tmp", id: String = sessionId) throws {
        let json = #"{"sessionId":"\#(id)","pid":\#(pid),"cwd":"\#(cwd)","status":"idle"}"#
        try json.write(to: registryDir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    func resumer(_ inspector: FakeInspector, _ driver: FakeDriver) -> SessionResumer {
        SessionResumer(registry: SessionRegistry(directory: registryDir), inspector: inspector, driver: driver)
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
