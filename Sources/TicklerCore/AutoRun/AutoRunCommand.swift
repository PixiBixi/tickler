import Foundation

/// The `claude` command line of a background run.
public enum AutoRunCommand {
    /// Appended to the system prompt so the answer ends with a block `AutoRunParser` can read.
    public static let reportFormat = """
    End your answer with this block, in English, nothing after it:
    Verdict: OK | WATCH | KO - one sentence
    Key figures:
    - 3 to 5 lines, before -> after
    Next step: the next action, or none
    """

    /// `--` ends the options, so a prompt starting with a dash is not read as a flag.
    public static func claudeArguments(prompt: String, sessionId: String?, mode: AutoRunMode) -> [String] {
        var args = ["-p"]
        if let sessionId {
            args += ["--resume", sessionId]
        }
        args += [
            "--output-format", "json", "--permission-mode", mode.permissionMode, "--permission-prompts", "none",
            "--append-system-prompt", reportFormat, "--", prompt,
        ]
        return args
    }

    /// The arguments reach the login shell as positional parameters, never inside the script text.
    public static func command(claudeArguments: [String]) -> [String] {
        ["env"] + SessionResumer.scrubbedVariables.flatMap { ["-u", $0] }
            + ["zsh", "-lic", #"exec claude "$@""#, "claude"] + claudeArguments
    }
}
