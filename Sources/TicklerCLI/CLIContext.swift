import Foundation
import TicklerCore

/// A text sink: the terminal for the real command, a buffer for tests.
public final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let sink: (@Sendable (String) -> Void)?

    public init(sink: (@Sendable (String) -> Void)? = nil) {
        self.sink = sink
    }

    public func write(_ text: String) {
        if let sink {
            sink(text)
        } else {
            lock.withLock { buffer += text }
        }
    }

    public func line(_ text: String) {
        write(text + "\n")
    }

    public var captured: String {
        lock.withLock { buffer }
    }
}

/// Everything a command takes from the outside world, so tests can swap the clock, the environment and the output.
public struct CLIContext: Sendable {
    public var environment: [String: String]
    public var currentDirectory: String
    public var calendar: Calendar
    public var now: @Sendable () -> Date
    public var readStdin: @Sendable () -> String
    public var notifyChange: @Sendable () -> Void
    public var makeDriver: @Sendable () -> TerminalDriver?
    public var fetchAppleReminders: @Sendable (String) throws -> Data
    public var stdout: Output
    public var stderr: Output
    public var liveRunner: CommandRunning = DirectRunner()
    /// A terminal gets the table; a pipe, a test or Claude gets one plain line per reminder.
    public var terminalWidth: Int? = Terminal.isInteractive ? Terminal.width : nil

    public static var live: CLIContext {
        CLIContext(
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: FileManager.default.currentDirectoryPath,
            calendar: .current,
            now: { Date() },
            readStdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
            notifyChange: { ChangeNotifier.post() },
            makeDriver: {
                let choice = TerminalChoice(rawValue: ProcessInfo.processInfo.environment["TICKLER_TERMINAL"] ?? "") ?? .auto
                return choice.driver()
            },
            fetchAppleReminders: { try AppleRemindersSource.fetch(list: $0) },
            stdout: Output { FileHandle.standardOutput.write(Data($0.utf8)) },
            stderr: Output { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }

    func openStore(_ options: GlobalOptions) throws -> ReminderStore {
        let path = options.db ?? TicklerDatabase.defaultPath(environment: environment)
        return try ReminderStore(database: TicklerDatabase(path: path), calendar: calendar, now: now, onChange: notifyChange)
    }

    /// A reminder the user can still see: soft-deleted ones answer "not found".
    func loadReminder(_ id: String, from store: ReminderStore) throws -> Reminder {
        let reminder = try store.require(id)
        guard reminder.status != .deleted else { throw StoreError.notFound(id) }
        return reminder
    }

    /// Strict format only, and never in the past: Claude resolves relative dates before calling.
    func parseFutureDate(_ value: String, flag: String) throws -> Date {
        guard let date = StrictDate.parse(value, calendar: calendar) else {
            throw CLIError.usage("\(flag) expects \"YYYY-MM-DD HH:MM\" (local time), got \"\(value)\"")
        }
        guard date >= now() else { throw CLIError.usage("\(flag) \"\(value)\" is in the past") }
        return date
    }

    func readNotes(_ value: String) -> String {
        guard value == "-" else { return value }
        return readStdin().trimmingCharacters(in: .newlines)
    }
}

/// Failures with an exit code of their own; not found is `StoreError.notFound`, exit 3.
public enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case runtime(String)

    public var description: String {
        switch self {
        case let .usage(message), let .runtime(message): message
        }
    }
}
