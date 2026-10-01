import ArgumentParser
import Foundation
import TicklerCore

/// Shell completion of reminder ids, each shown with its title. Open reminders only, nearest first.
enum IDCompletion {
    @Sendable
    static func complete(_ words: [String], _: Int, _ prefix: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let path = words.firstIndex(of: "--db").flatMap { $0 + 1 < words.count ? words[$0 + 1] : nil }
            ?? TicklerDatabase.defaultPath(environment: environment)
        guard FileManager.default.fileExists(atPath: path),
              let store = try? ReminderStore(database: TicklerDatabase(path: path), onChange: {}),
              let reminders = try? store.list(ReminderFilter(due: .all)) else { return [] }
        return reminders.filter { $0.id.hasPrefix(prefix) }.map { candidate($0, shell: environment["SAP_SHELL"]) }
    }

    /// zsh `_describe` reads "value:description", fish "value<TAB>description", bash takes the bare value.
    static func candidate(_ reminder: Reminder, shell: String?) -> String {
        let description = "\(StrictDate.format(reminder.dueAt)) \(reminder.title)"
        switch shell {
        case "zsh": return "\(reminder.id):\(description.replacingOccurrences(of: ":", with: "\\:"))"
        case "fish": return "\(reminder.id)\t\(description)"
        default: return reminder.id
        }
    }
}

/// `tickler completion zsh`: a short name for ArgumentParser's completion script.
struct CompletionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Print the shell completion script.",
        discussion: "zsh: add `source <(tickler completion zsh)` to ~/.zshrc."
    )

    enum Shell: String, ExpressibleByArgument, CaseIterable {
        case zsh, bash, fish
    }

    @Argument(help: "zsh, bash or fish.") var shell: Shell = .zsh

    func run() throws {
        let kind: CompletionShell = switch shell {
        case .zsh: .zsh
        case .bash: .bash
        case .fish: .fish
        }
        print(TicklerCommand.completionScript(for: kind))
    }
}
