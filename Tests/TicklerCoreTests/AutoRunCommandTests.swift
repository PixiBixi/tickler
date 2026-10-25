import Testing
@testable import TicklerCore

struct AutoRunCommandTests {
    @Test func readModeArgs() {
        let args = AutoRunCommand.claudeArguments(prompt: "go", sessionId: "abc", mode: .read)
        #expect(args == [
            "-p", "--resume", "abc", "--output-format", "json", "--permission-mode", "dontAsk",
            "--permission-prompts", "none", "--", "go\n\n" + AutoRunCommand.reportFormat,
        ])
        #expect(!args.contains("bypassPermissions"))
        #expect(!args.contains("--append-system-prompt"))
    }

    @Test func writeModeArgs() {
        let args = AutoRunCommand.claudeArguments(prompt: "go", sessionId: "abc", mode: .write)
        #expect(args.contains("acceptEdits"))
    }

    @Test func noSessionDropsResume() {
        let args = AutoRunCommand.claudeArguments(prompt: "go", sessionId: nil, mode: .read)
        #expect(!args.contains("--resume"))
        #expect(args.first == "-p")
    }

    @Test func messageStartingWithDash() {
        let args = AutoRunCommand.claudeArguments(prompt: "-x", sessionId: nil, mode: .read)
        #expect(Array(args.suffix(2)) == ["--", "-x\n\n" + AutoRunCommand.reportFormat])
    }

    @Test func reportFormatText() {
        #expect(AutoRunCommand.reportFormat == """
        End your answer with this block, in English, nothing after it:
        Verdict: OK | WATCH | KO - one sentence
        Key figures:
        - 3 to 5 lines, before -> after
        Next step: the next action, or none
        """)
    }

    @Test func commandScrubsSessionVars() {
        let args = AutoRunCommand.claudeArguments(prompt: "secret prompt", sessionId: "abc", mode: .read)
        let command = AutoRunCommand.command(claudeArguments: args)
        #expect(command.first == "env")
        #expect(command.contains("CLAUDE_CODE_SESSION_ID"))
        let index = command.firstIndex(of: "CLAUDE_CODE_SESSION_ID")
        #expect(index.map { command[$0 - 1] } == "-u")
        #expect(command.contains(AutoRunCommand.script))
        #expect(!AutoRunCommand.script.contains("secret prompt"))
        #expect(!AutoRunCommand.script.contains("exec"))
        let zsh = command.firstIndex(of: "zsh") ?? 0
        #expect(Array(command[zsh...].prefix(4)) == ["zsh", "-lic", AutoRunCommand.script, "claude"])
        #expect(Array(command[(zsh + 4)...]) == args)
    }
}
