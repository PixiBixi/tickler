import ArgumentParser
import Foundation
import TicklerCore

struct AddCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a reminder.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "What to be reminded of.") var title: String
    @Option(help: "Due date, \"YYYY-MM-DD HH:MM\" in local time.") var at: String
    @Option(help: "Notes, or - to read them from stdin.") var notes: String?
    @Option(name: .customLong("link"), help: "A URL to attach; repeatable.") var links: [String] = []
    @Option(help: "Claude session id. Defaults to $CLAUDE_CODE_SESSION_ID.") var session: String?
    @Option(help: "Session folder. Defaults to the current directory when a session id is known.") var cwd: String?
    @Option(help: "First message sent to Claude when the session is resumed.") var prompt: String?
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("the title is empty") }
    }

    func execute(_ context: CLIContext) throws {
        let due = try context.parseFutureDate(at, flag: "--at")
        let envSession = context.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let sessionId = session ?? envSession
        // A human without a session gets no folder: a cwd alone would offer a Resume that cannot work.
        let folder = cwd ?? (sessionId == nil ? nil : context.currentDirectory)
        let draft = ReminderDraft(
            title: title, notes: notes.map(context.readNotes) ?? "", dueAt: due, links: links,
            sessionId: sessionId, cwd: folder, resumePrompt: prompt, source: sessionId == nil ? .human : .claude
        )
        let store = try context.openStore(options)
        try context.printResult(store.add(draft), store: store, json: json)
    }
}
