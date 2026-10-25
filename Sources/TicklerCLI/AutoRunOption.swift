import ArgumentParser
import TicklerCore

/// The values of `--auto-run`; `off` only means something on `edit`.
enum AutoRunOption: String, ExpressibleByArgument, CaseIterable {
    case read, write, off

    static let addUsage = "read or write"
    static let editUsage = "read, write or off"

    var mode: AutoRunMode? {
        AutoRunMode(rawValue: rawValue)
    }
}
