import ArgumentParser
import Foundation
import TicklerCore

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "The Claude Code skill that teaches Claude to use Tickler.",
        subcommands: [SkillInstallCommand.self, SkillStatusCommand.self]
    )
}

struct SkillInstallCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install or update the skill in ~/.claude/skills/tickler ($CLAUDE_CONFIG_DIR is honored)."
    )

    @Flag(help: "Replace a skill that was edited, or not installed by Tickler.") var force = false
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let directory = ClaudeSkill.directory(environment: context.environment)
        let path = ClaudeSkill.file(in: directory).path
        do {
            switch try ClaudeSkill.install(in: directory, force: force) {
            case .notInstalled: context.stdout.line("installed\t\(path)")
            case .outdated: context.stdout.line("updated\t\(path)")
            case .edited: context.stdout.line("replaced\t\(path)")
            case .upToDate: context.stdout.line("up to date\t\(path)")
            }
        } catch let error as ClaudeSkill.InstallError {
            throw CLIError.runtime(error.description)
        }
    }
}

struct SkillStatusCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the skill is installed and current.")
    @OptionGroup var options: GlobalOptions

    func execute(_ context: CLIContext) throws {
        let directory = ClaudeSkill.directory(environment: context.environment)
        let state = switch ClaudeSkill.state(in: directory) {
        case .notInstalled: "not installed"
        case .upToDate: "up to date"
        case .outdated: "outdated, run: tickler skill install"
        case .edited: "edited, or not installed by Tickler (tickler skill install --force replaces it)"
        }
        context.stdout.line("\(state)\t\(ClaudeSkill.file(in: directory).path)")
    }
}
