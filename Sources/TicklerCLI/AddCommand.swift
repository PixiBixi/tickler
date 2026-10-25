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
    @Option(help: "Run the resume prompt in the background when due, in Tickler.app: \(AutoRunOption.addUsage).")
    var autoRun: AutoRunOption?
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("the title is empty") }
        guard at != nil || when != nil else { throw ValidationError("pass --at, --when, or both") }
        if let when, Trigger(when) == nil {
            throw ValidationError("--when expects \(Trigger.usage), got \"\(when)\"")
        }
        if autoRun == .off {
            throw ValidationError("--auto-run expects \(AutoRunOption.addUsage), got \"off\"")
        }
        if autoRun != nil, ReminderStore.normalized(prompt) == nil {
            throw ValidationError("--auto-run needs --prompt: the run has no one to answer a question")
        }
    }

    func execute(_ context: CLIContext) throws {
        let trigger = when.flatMap(Trigger.init)
        let due = try at.map { try context.parseFutureDate($0, flag: "--at") }
            ?? Trigger.defaultDeadline(after: context.now(), calendar: context.calendar)
        let noteText = notes.map(context.readNotes) ?? ""
        if let trigger {
            try requireSupportedLink(
                trigger, LinkExtractor.links(reminderId: "", notes: noteText, explicit: links),
                gitlabHosts: GitLabHosts.current(environment: context.environment)
            )
        }
        let envSession = context.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let sessionId = session ?? envSession
        // A human without a session gets no folder: a cwd alone would offer a Resume that cannot work.
        let folder = cwd ?? (sessionId == nil ? nil : context.currentDirectory)
        if autoRun != nil, folder?.isEmpty != false {
            throw CLIError.usage("--auto-run needs --cwd, or a session id so the current directory is used")
        }
        let draft = ReminderDraft(
            title: title, notes: noteText, dueAt: due, links: links, sessionId: sessionId, cwd: folder,
            resumePrompt: prompt, source: sessionId == nil ? .human : .claude, trigger: trigger,
            autoRun: autoRun?.mode
        )
        let store = try context.openStore(options)
        try context.printResult(store.add(draft), store: store, json: json)
    }
}

/// A trigger needs links it can watch: refused up front rather than waiting forever. The check is the one the
/// watcher runs (`LiveTarget`), and a trigger waits for every link of a supported kind, so one it cannot query is refused too.
func requireSupportedLink(_ trigger: Trigger, _ links: [ReminderLink], gitlabHosts: Set<String>) throws {
    let candidates = links.filter { trigger.supports($0.kind) }
    guard !candidates.isEmpty else {
        let kinds = trigger.supports(.jira) ? "a Jira issue" : "a GitLab merge request or a GitHub pull request"
        throw CLIError.usage("--when \(trigger.rawValue) needs \(kinds) among the links")
    }
    if let unwatchable = candidates.first(where: { LiveTarget(link: $0) == nil }) {
        throw CLIError.usage("--when \(trigger.rawValue) cannot watch \(unwatchable.url): not a link Tickler can query")
    }
    for case let .gitlabMR(host, _, _)? in candidates.map(LiveTarget.init(link:)) where !gitlabHosts.contains(host) {
        throw CLIError.usage("--when \(trigger.rawValue): \(LiveError.unknownHost(host))")
    }
}
