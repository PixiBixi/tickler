import ArgumentParser
import Foundation
import TicklerCore

struct AddCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a reminder.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "What to be reminded of.") var title: String
    @Option(help: "Earliest time, \"YYYY-MM-DD HH:MM\" or \"YYYY-MM-DD\" (working start). Default: now. With --when, the fallback.")
    var at: String?
    @Flag(help: "Keep exactly the --at time, even at night or on a weekend: the planner never moves it.") var fixed = false
    @Option(help: "How long it takes: 15m, 1h, 90m. Default: the working-day setting (15m).") var duration: String?
    @Option(help: "Latest acceptable start, \"YYYY-MM-DD[ HH:MM]\"; a bare day means the end of the working day. Not with --fixed.")
    var deadline: String?
    @Option(help: "Event that makes it due now: \(Trigger.usage).") var when: String?
    @Option(help: "Notes, or - to read them from stdin.") var notes: String?
    @Option(name: .customLong("link"), help: "A URL to attach; repeatable.") var links: [String] = []
    @Option(help: "Claude session id. Defaults to $CLAUDE_CODE_SESSION_ID.") var session: String?
    @Option(help: "Session folder. Defaults to the current directory when a session id is known.") var cwd: String?
    @Option(help: "First message sent to Claude when the session is resumed.") var prompt: String?
    @Option(help: "Run the resume prompt in the background when due, in Tickler.app: \(AutoRunOption.addUsage).")
    var autoRun: AutoRunOption?
    @Flag(help: "Resume starts a new session in the folder with the prompt; use it with a handoff file.") var fresh = false
    @Flag(help: "Print the reminder as JSON.") var json = false

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("the title is empty") }
        if fixed, at == nil {
            throw ValidationError("--fixed needs --at")
        }
        if fixed, deadline != nil {
            throw ValidationError("--deadline cannot be used with --fixed")
        }
        if let when, Trigger(when) == nil {
            throw ValidationError("--when expects \(Trigger.usage), got \"\(when)\"")
        }
        if autoRun == .off {
            throw ValidationError("--auto-run expects \(AutoRunOption.addUsage), got \"off\"")
        }
        if autoRun != nil, at == nil, when == nil {
            throw ValidationError("--auto-run needs --at, --when, or both")
        }
        if autoRun != nil, ReminderStore.normalized(prompt) == nil {
            throw ValidationError("--auto-run needs --prompt: the run has no one to answer a question")
        }
        if fresh, ReminderStore.normalized(prompt) == nil {
            throw ValidationError("--fresh needs --prompt: it is the first message of the new session")
        }
    }

    func execute(_ context: CLIContext) throws {
        let trigger = when.flatMap(Trigger.init)
        let checkSchedule = try context.scheduleForChecks(options)
        let asked = try at.map { try context.parseScheduleDate($0, flag: "--at", dayTime: checkSchedule.start) }
        let minutes = try duration.map { try context.parseDurationMinutes($0, schedule: checkSchedule) }
        let latest = try deadline.map { try context.parseScheduleDate($0, flag: "--deadline", dayTime: checkSchedule.end).date }
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
        // Resume has no session to fall back on: the folder is the only place to start the new one.
        let folderForFresh = fresh ? folder ?? context.currentDirectory : folder
        // The store is opened after every usage check: a usage error leaves no database behind.
        let store = try context.openStore(options)
        let schedule = try store.schedule()
        let fallback = trigger == nil
            ? context.now()
            : Trigger.defaultDeadline(after: context.now(), calendar: context.calendar, schedule: schedule)
        let start = asked?.date ?? fallback
        let draft = ReminderDraft(
            title: title, notes: noteText, dueAt: start, links: links, sessionId: sessionId, cwd: folderForFresh,
            resumePrompt: prompt, source: sessionId == nil ? .human : .claude, trigger: trigger,
            autoRun: autoRun?.mode, fresh: fresh, durationMinutes: minutes ?? schedule.defaultDurationMinutes,
            fixed: fixed, notBefore: fixed ? nil : start, deadline: latest
        )
        let added = try store.add(draft)
        let outcome = try context.runSchedule(store, cause: .reminderAdded, touched: added.id, isNew: true)
        let shown = try store.require(added.id)
        let typed = asked.flatMap { $0.hasTime && !fixed ? $0.date : nil }
        try printSchedule(outcome, placed: shown, asked: typed, context: context, store: store, json: json)
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
