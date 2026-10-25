import Foundation
import Testing
@testable import TicklerCore

struct AutoRunParserTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func parse(
        _ stdout: Data, stderr: String = "", status: Int32 = 0, timedOut: Bool = false, cancelled: Bool = false
    ) -> RunResult {
        AutoRunParser.parse(stdout: stdout, stderr: Data(stderr.utf8), status: status, timedOut: timedOut, cancelled: cancelled)
    }

    private func json(result: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": "success", "is_error": false, "result": result, "session_id": "s1",
        ])
    }

    @Test func parsesSuccess() throws {
        let result = try parse(fixture("claude-result-ok"))
        #expect(result.state == .succeeded)
        #expect(result.verdict == .ok)
        #expect(result.headline == "rollout is healthy")
        #expect(result.figures.count == 3)
        #expect(result.figures.first == "error rate: 1.2% -> 0.4%")
        #expect(result.nextStep == "check again on Monday")
        #expect(result.costUsd == 0.0521)
        #expect(result.sessionId == "de9cdbf9-c71d-4170-addf-7f8a96df4d62")
        #expect(result.denials == 0)
        #expect(result.durationMs == 3875)
        #expect(result.output?.contains("I checked the rollout") == true)
    }

    @Test func parsesIsError() throws {
        let result = try parse(fixture("claude-result-error"))
        #expect(result.state == .failed)
        #expect(result.error == "claude reported an error")
        #expect(result.denials == 1)
        #expect(result.error?.contains("leak") == false)
    }

    @Test func lowercaseVerdict() {
        let report = AutoRunParser.report(in: "verdict: watch - x")
        #expect(report.verdict == .watch)
        #expect(report.headline == "x")
    }

    @Test func verdictAmidFrenchText() {
        let text = "Voici le bilan.\n\n**Verdict: KO - le job a échoué**\nKey figures:\n- 1 -> 2\n- a -> b\nNext step: relancer"
        let report = AutoRunParser.report(in: text)
        #expect(report.verdict == .ko)
        #expect(report.headline == "le job a échoué")
        #expect(report.figures == ["1 -> 2", "a -> b"])
        #expect(report.nextStep == "relancer")
    }

    @Test func missingBlockFallsBackToFirstLine() throws {
        let result = try parse(json(result: "\nAll good, nothing to see.\nSecond line"))
        #expect(result.state == .succeeded)
        #expect(result.verdict == .unknown)
        #expect(result.headline == "All good, nothing to see.")
    }

    @Test func nextStepNone() {
        #expect(AutoRunParser.report(in: "Verdict: OK - fine\nNext step: none").nextStep == nil)
    }

    @Test func lastVerdictWins() {
        let report = AutoRunParser.report(in: "Verdict: OK - first\nmore\nVerdict: KO - second")
        #expect(report.verdict == .ko)
        #expect(report.headline == "second")
    }

    @Test func timeoutWins() throws {
        let result = try parse(fixture("claude-result-ok"), timedOut: true)
        #expect(result.state == .failed)
        #expect(result.error == "Timed out after 30 min")
    }

    @Test func cancelled() throws {
        let result = try parse(fixture("claude-result-ok"), cancelled: true)
        #expect(result.state == .cancelled)
        #expect(result.error == "Stopped")
    }

    @Test func garbageStdout() {
        let result = parse(Data("not json".utf8))
        #expect(result.state == .failed)
        #expect(result.error == "Unreadable claude output")
    }

    @Test func nonZeroStatusWithoutOutput() {
        let result = parse(Data(), status: 2)
        #expect(result.state == .failed)
        #expect(result.error == "claude exited with status 2")
    }

    @Test func stderrTailKept() {
        let lines = (1 ... 25).map { "line \($0)" }.joined(separator: "\n")
        let result = parse(Data(), stderr: lines, status: 1)
        let error = result.error ?? ""
        #expect(error.hasPrefix("claude exited with status 1\n"))
        #expect(error.hasSuffix("line 25"))
        #expect(error.contains("line 6"))
        #expect(!error.contains("line 5\n"))
        #expect(error.split(separator: "\n").count == 21)
    }
}
