import ArgumentParser

public struct TicklerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tickler",
        abstract: "Reminders written by Claude Code, shown by Tickler.app."
    )

    public init() {}
}
