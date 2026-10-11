import Foundation
import Testing
@testable import TicklerCore

struct ProcessOutcomeTests {
    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    @Test func readsBothOutputs() throws {
        let outcome = try ProcessOutcome.run(shell("echo out; echo err >&2; exit 3"), tool: "sh", timeout: 10)
        #expect(outcome.status == 3)
        #expect(String(decoding: outcome.output, as: UTF8.self) == "out\n")
        #expect(String(decoding: outcome.errors, as: UTF8.self) == "err\n")
    }

    @Test func readsAnOutputLargerThanThePipeBuffer() throws {
        let outcome = try ProcessOutcome.run(shell("head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2"), tool: "sh", timeout: 10)
        #expect(outcome.output.count == 300_000)
        #expect(outcome.errors.count == 300_000)
    }

    @Test func returnsWhenAChildKeepsThePipeOpen() throws {
        let start = Date()
        let outcome = try ProcessOutcome.run(shell("sleep 8 & echo done"), tool: "sh", timeout: 20)
        #expect(String(decoding: outcome.output, as: UTF8.self) == "done\n")
        #expect(Date().timeIntervalSince(start) < ProcessOutcome.drainGrace + 3)
    }

    @Test func hungToolsLeaveTheCooperativePoolFree() async throws {
        let runner = DirectRunner(timeout: 10)
        let hung = (0 ..< ProcessInfo.processInfo.activeProcessorCount * 2).map { _ in
            Task { try await runner.run("sleep", ["6"]) }
        }
        let start = Date()
        _ = await Task.detached { 1 }.value
        // A blocked pool waits for the 6 s sleeps; 4 s leaves room for slow CI runners (seen at 2.4 s).
        #expect(Date().timeIntervalSince(start) < 4)
        for task in hung {
            _ = try await task.value
        }
    }

    @Test func directRunnerStopsAToolThatNeverReturns() async {
        await #expect(throws: LiveError.timedOut(tool: "sleep", seconds: 0.5)) {
            try await DirectRunner(timeout: 0.5).run("sleep", ["5"])
        }
    }

    @Test func terminalCommandTimesOutAsAResumeError() {
        #expect(throws: ResumeError.terminal("sleep: timed out after 0.5 s")) {
            try WezTermDriver.execute(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.5)
        }
    }
}
