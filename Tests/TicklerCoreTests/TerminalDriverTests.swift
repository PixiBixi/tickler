import Foundation
import Testing
@testable import TicklerCore

final class RecordingScriptRunner: ScriptRunning, @unchecked Sendable {
    var calls: [(source: String, arguments: [String])] = []
    var reply = ""

    func run(_ source: String, arguments: [String]) throws -> String {
        calls.append((source, arguments))
        return reply
    }
}

struct TerminalDriverTests {
    @Test func shellJoinQuotesOnlyWhatNeedsIt() {
        #expect(shellJoin(["env", "-u", "CLAUDECODE", "zsh", "-lic", "claude --resume abc"]) ==
            "env -u CLAUDECODE zsh -lic 'claude --resume abc'")
        #expect(shellJoin(["/Users/me/it's here"]) == #"'/Users/me/it'\''s here'"#)
        #expect(shellJoin(["$(rm -rf ~)"]) == "'$(rm -rf ~)'")
    }

    @Test func iTermSpawnPassesTheFolderAndCommandAsArguments() throws {
        let runner = RecordingScriptRunner()
        runner.reply = "w0t0p0:ABC"
        let pane = try AppleScriptTerminalDriver.iTerm(runner: runner).spawn(cwd: "/tmp/a b", command: ["claude", "--resume", "x"])
        #expect(pane == "w0t0p0:ABC")
        #expect(runner.calls.first?.arguments == ["/tmp/a b", "cd '/tmp/a b' && claude --resume x"])
        #expect(runner.calls.first?.source.contains("/tmp") == false)
    }

    @Test func ghosttyFindsTerminalsByTTY() throws {
        let runner = RecordingScriptRunner()
        let driver = AppleScriptTerminalDriver.ghostty(runner: runner)
        #expect(try driver.paneId(forTTY: "/dev/ttys004") == nil)
        runner.reply = "T-42"
        #expect(try driver.paneId(forTTY: "/dev/ttys004") == "T-42")
        #expect(runner.calls.last?.arguments == ["/dev/ttys004"])
    }

    @Test func compositeFindsTheSessionInWhicheverTerminalHoldsIt() throws {
        let wezterm = FakeDriver()
        let iterm = FakeDriver()
        iterm.panes = ["/dev/ttys009": "S1"]
        let composite = CompositeTerminalDriver(members: [
            .init(name: "wezterm", driver: wezterm, installed: true),
            .init(name: "iterm", driver: iterm, installed: true),
        ])
        let pane = try #require(try composite.paneId(forTTY: "/dev/ttys009"))
        #expect(pane == "iterm:S1")
        try composite.activate(paneId: pane)
        #expect(iterm.calls == ["activate S1", "front"])
        #expect(wezterm.calls.isEmpty)
    }

    @Test func aTerminalThatCannotSearchIsOnlyAGuess() throws {
        let ghostty = FakeDriver()
        ghostty.panes = ["/dev/ttys001": ""]
        let iterm = FakeDriver()
        iterm.panes = ["/dev/ttys001": "S9"]
        let both = CompositeTerminalDriver(members: [
            .init(name: "ghostty", driver: ghostty, installed: true),
            .init(name: "iterm", driver: iterm, installed: true),
        ])
        #expect(try both.paneId(forTTY: "/dev/ttys001") == "iterm:S9")
        let alone = CompositeTerminalDriver(members: [.init(name: "ghostty", driver: ghostty, installed: true)])
        #expect(try alone.paneId(forTTY: "/dev/ttys001") == "ghostty:")
        try alone.activate(paneId: "ghostty:")
        #expect(ghostty.calls == ["front"])
    }

    @Test func questionMarkMeansCannotTell() throws {
        let runner = RecordingScriptRunner()
        runner.reply = "?"
        #expect(try AppleScriptTerminalDriver.ghostty(runner: runner).paneId(forTTY: "/dev/ttys001") == "")
    }

    @Test func compositeSpawnsInThePreferredRunningTerminal() throws {
        let ghostty = FakeDriver()
        ghostty.running = false
        let iterm = FakeDriver()
        let composite = CompositeTerminalDriver(members: [
            .init(name: "ghostty", driver: ghostty, installed: true),
            .init(name: "iterm", driver: iterm, installed: true),
        ])
        #expect(try composite.spawn(cwd: "/tmp", command: ["x"]) == "iterm:42")
        iterm.running = false
        #expect(try composite.spawn(cwd: "/tmp", command: ["x"]) == "ghostty:")
        #expect(ghostty.calls == ["start /tmp"])
    }

    @Test func aForcedChoiceWinsOverARunningTerminal() throws {
        let iterm = FakeDriver()
        iterm.running = false
        let wezterm = FakeDriver()
        let composite = CompositeTerminalDriver(members: [
            .init(name: "iterm", driver: iterm, installed: true),
            .init(name: "wezterm", driver: wezterm, installed: true),
        ], forced: true)
        #expect(try composite.spawn(cwd: "/tmp", command: ["x"]) == "iterm:")
        #expect(iterm.calls == ["start /tmp"])
        #expect(wezterm.calls.isEmpty)
    }

    @Test func choicePutsTheChosenTerminalFirst() {
        let order = TerminalChoice.iterm.driver().members.map(\.name)
        #expect(order == ["iterm", "wezterm", "ghostty"])
        #expect(TerminalChoice.auto.driver().members.map(\.name) == ["wezterm", "ghostty", "iterm"])
    }

    @Test func availableAlwaysOffersAutomaticFirst() {
        let choices = TerminalChoice.available()
        #expect(choices.first == .auto)
        #expect(Set(choices).isSubset(of: Set(TerminalChoice.allCases)))
    }
}
