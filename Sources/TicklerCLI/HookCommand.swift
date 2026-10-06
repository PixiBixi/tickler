import ArgumentParser
import Foundation
import TicklerCore

struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "The Claude Code SessionStart hook that tells Claude about the session's reminders.",
        subcommands: [HookSessionStartCommand.self, HookInstallCommand.self, HookStatusCommand.self, HookUninstallCommand.self]
    )
}

struct HookSessionStartCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "session-start",
        abstract: "Run by Claude Code when a session starts: prints the reminders of the session's repository."
    )

    @OptionGroup var options: GlobalOptions

    /// Never fails: a hook error would greet every session, so any problem prints nothing.
    func execute(_ context: CLIContext) throws {
        let input = (try? JSONSerialization.jsonObject(with: Data(context.readStdin().utf8))) as? [String: Any]
        let folder = (input?["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? context.currentDirectory
        guard let store = try? context.openStore(options),
              let reminders = try? store.list(ReminderFilter(due: .all)),
              let text = SessionDigest.text(
                  reminders: reminders, sessionFolder: folder, now: context.now(), calendar: context.calendar,
                  gitRoot: GitRoot.budgeted(lookup: context.gitRoot), folderExists: context.folderExists
              )
        else { return }
        let output = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": text]]
        let writing: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: writing) else { return }
        context.stdout.line(String(decoding: data, as: UTF8.self))
    }
}

struct HookInstallCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Add the hook to ~/.claude/settings.json ($CLAUDE_CONFIG_DIR is honored), or update it."
    )

    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let settings = ClaudeHook.settingsFile(environment: context.environment)
        guard let tickler = ClaudeHook.ticklerPath(environment: context.environment) else {
            throw CLIError.runtime("tickler is not on PATH: the hook needs a stable path to run it")
        }
        do {
            switch try ClaudeHook.install(settings: settings, command: ClaudeHook.command(ticklerPath: tickler)) {
            case .notInstalled: context.stdout.line("installed\t\(settings.path)")
            case .outdated: context.stdout.line("updated\t\(settings.path)")
            case .upToDate: context.stdout.line("up to date\t\(settings.path)")
            }
        } catch let error as ClaudeHook.InstallError {
            throw CLIError.runtime(error.description)
        }
    }
}

struct HookStatusCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the hook is installed.")
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let settings = ClaudeHook.settingsFile(environment: context.environment)
        let command = ClaudeHook.ticklerPath(environment: context.environment).map(ClaudeHook.command(ticklerPath:)) ?? ""
        let state = switch ClaudeHook.state(settings: settings, command: command) {
        case .notInstalled: "not installed"
        case .upToDate: "installed"
        case .outdated: command.isEmpty ? "installed" : "outdated, run: tickler hook install"
        }
        context.stdout.line("\(state)\t\(settings.path)")
    }
}

struct HookUninstallCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove the hook from the Claude Code settings.")
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let settings = ClaudeHook.settingsFile(environment: context.environment)
        do {
            let removed = try ClaudeHook.uninstall(settings: settings)
            context.stdout.line("\(removed ? "removed" : "not installed")\t\(settings.path)")
        } catch let error as ClaudeHook.InstallError {
            throw CLIError.runtime(error.description)
        }
    }
}
