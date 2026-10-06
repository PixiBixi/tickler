import ArgumentParser
import Foundation
import TicklerCore

struct AddCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a reminder.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "What to be reminded of.") var title: String
    @Option(help: "Due date, \"YYYY-MM-DD HH:MM\" in local time. With --when, the fallback deadline (default: 3 working days, 09:30).")
    var at: String?
    @Option(help: "Event that makes it due now: \(Trigger.usage).") var when: String?
    @Option(help: "Notes, or - to read them from stdin.") var notes: String?
    @Option(name: .customLong("link"), help: "A URL to attach; repeatable.") var links: [String] = []
    @Option(help: "Claude session id. Defaults to $CLAUDE_CODE_SESSION_ID.") var session: String?
    @Option(help: "Session folder. Defaults to the current directory when a session id is known.") var cwd: String?
    @Option(help: "First message sent to Claude when the session is resumed.") var prompt: String?
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("the title is empty") }
        guard at != nil || when != nil else { throw ValidationError("pass --at, --when, or both") }
        if let when, Trigger(when) == nil {
            throw ValidationError("--when expects \(Trigger.usage), got \"\(when)\"")
        }
    }

    func execute(_ context: CLIContext) throws {
        let trigger = when.flatMap(Trigger.init)
        let due = try at.map { try context.parseFutureDate($0, flag: "--at") }
            ?? Trigger.defaultDeadline(after: context.now(), calendar: context.calendar)
        let noteText = notes.map(context.readNotes) ?? ""
        if let trigger {
            try requireSupportedLink(trigger, LinkExtractor.links(reminderId: "", notes: noteText, explicit: links))
        }
        let envSession = context.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let sessionId = session ?? envSession
        // A human without a session gets no folder: a cwd alone would offer a Resume that cannot work.
        let folder = cwd ?? (sessionId == nil ? nil : context.currentDirectory)
        let draft = ReminderDraft(
            title: title, notes: noteText, dueAt: due, links: links, sessionId: sessionId, cwd: folder,
            resumePrompt: prompt, source: sessionId == nil ? .human : .claude, trigger: trigger
        )
        let store = try context.openStore(options)
        try context.printResult(store.add(draft), store: store, json: json)
    }
}

/// A trigger needs a link it can watch: refused up front rather than waiting forever.
func requireSupportedLink(_ trigger: Trigger, _ links: [ReminderLink]) throws {
    guard links.contains(where: { trigger.supports($0.kind) }) else {
        let kinds = trigger.supports(.jira) ? "a Jira issue" : "a GitLab merge request or a GitHub pull request"
        throw CLIError.usage("--when \(trigger.rawValue) needs \(kinds) among the links")
    }
}
