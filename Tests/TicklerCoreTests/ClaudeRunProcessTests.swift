import Foundation
import Testing
@testable import TicklerCore

struct ClaudeRunProcessTests {
    private func shell(_ script: String, cwd: String = "/tmp", timeout: TimeInterval = 10) -> ClaudeRunProcess {
        ClaudeRunProcess(command: ["/bin/sh", "-c", script], cwd: cwd, timeout: timeout)
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test func capturesBothStreams() async {
        let result = await shell("echo out; echo err >&2; exit 3").run()
        #expect(result.status == 3)
        #expect(text(result.stdout) == "out\n")
        #expect(text(result.stderr) == "err\n")
        #expect(!result.timedOut)
        #expect(!result.cancelled)
    }

    @Test func runsInCwd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await shell("pwd -P", cwd: dir.path).run()
        let expected = dir.resolvingSymlinksInPath().path
        let printed = text(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path == expected)
    }

    @Test func timesOut() async {
        let start = Date()
        let result = await shell("sleep 30", timeout: 0.5).run()
        #expect(result.timedOut)
        #expect(!result.cancelled)
        // Far below the sleep, loose enough for a loaded CI runner (3.1 s seen).
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func cancelTerminates() async throws {
        let process = shell("sleep 30")
        let start = Date()
        let task = Task { await process.run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        process.cancel()
        let result = await task.value
        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// The login shell runs `claude` as a child, not through `exec`: a stop must reach it too.
    @Test func cancelStopsGrandchildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let process = shell("sleep 30 & echo $! > \(pidFile); wait")
        let task = Task { await process.run() }
        let pid =
            try #require(await poll {
                Int32(text(FileManager.default.contents(atPath: pidFile) ?? Data()).trimmingCharacters(in: .whitespacesAndNewlines))
            })
        process.cancel()
        _ = await task.value
        // The orphan is reaped by launchd, not by us: give it a moment.
        #expect(await poll { kill(pid, 0) != 0 ? true : nil } == true)
    }

    /// Retries every 50 ms for up to 10 s: parallel suites can starve a fixed sleep.
    private func poll<T>(_ probe: () -> T?) async -> T? {
        for _ in 0 ..< 200 {
            if let value = probe() {
                return value
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    @Test func cancelBeforeRunDoesNotLaunch() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let process = shell("touch \(marker)")
        process.cancel()
        let result = await process.run()
        #expect(result.cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func cancelAfterExitIsANoOp() async {
        let process = shell("echo done")
        let result = await process.run()
        process.cancel()
        #expect(result.status == 0)
        #expect(!result.cancelled)
    }

    @Test func largeOutputDrained() async {
        let result = await shell("head -c 1000000 /dev/zero; head -c 1000000 /dev/zero >&2").run()
        #expect(result.stdout.count == 1_000_000)
        #expect(result.stderr.count == 1_000_000)
    }

    @Test func missingCwd() async {
        let result = await shell("echo hi", cwd: "/nonexistent-tickler-dir").run()
        #expect(result.status == -1)
        #expect(!result.stderr.isEmpty)
    }

    @Test func missingExecutable() async {
        let result = await ClaudeRunProcess(command: ["/nonexistent/tool"], cwd: "/tmp").run()
        #expect(result.status == -1)
        #expect(!result.stderr.isEmpty)
    }

    @Test func bareNameGoesThroughEnv() async {
        let result = await ClaudeRunProcess(command: ["echo", "hi"], cwd: "/tmp").run()
        #expect(result.status == 0)
        #expect(text(result.stdout) == "hi\n")
    }
}
