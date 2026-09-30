import Foundation
import TicklerCore

/// One open reminder as the JXA script prints it.
struct AppleReminderRow: Decodable, Equatable {
    let id: String
    let name: String
    let body: String?
    let due: String?
}

struct AppleImportSummary: Equatable {
    var imported = 0
    var alreadyImported = 0
    var withoutDate: [String] = []
}

enum AppleImport {
    static func decode(_ data: Data) throws -> [AppleReminderRow] {
        do {
            return try JSONDecoder().decode([AppleReminderRow].self, from: data)
        } catch {
            throw CLIError.runtime("cannot read the Reminders output: \(error.localizedDescription)")
        }
    }

    /// JavaScript `toISOString()` writes milliseconds, other sources may not.
    static func parseDue(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Past due dates are kept as they are: they show up overdue, which is the point of importing them.
    static func importRows(_ rows: [AppleReminderRow], into store: ReminderStore) throws -> AppleImportSummary {
        var summary = AppleImportSummary()
        for row in rows {
            if try store.find(externalRef: row.id) != nil {
                summary.alreadyImported += 1
                continue
            }
            guard let due = parseDue(row.due) else {
                summary.withoutDate.append(row.name)
                continue
            }
            let footer = AppleReminderFooter.parse(notes: row.body ?? "")
            try store.add(ReminderDraft(
                title: row.name, notes: footer.notes, dueAt: due, sessionId: footer.sessionId, cwd: footer.cwd,
                source: .claude, externalRef: row.id
            ))
            summary.imported += 1
        }
        return summary
    }
}

enum AppleRemindersSource {
    /// Arrays per property: one Apple Event each, instead of one per reminder and property.
    static let script = """
    function run(argv) {
      const items = Application('Reminders').lists.byName(argv[0]).reminders.whose({completed: false});
      const ids = items.id(), names = items.name(), bodies = items.body(), remind = items.remindMeDate(), due = items.dueDate();
      return JSON.stringify(ids.map((id, i) => {
        const date = remind[i] || due[i];
        return {id: id, name: names[i], body: bodies[i] || '', due: date ? date.toISOString() : null};
      }));
    }
    """

    static func fetch(list: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, list]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw CLIError.runtime("cannot run osascript: \(error.localizedDescription)") }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.runtime("cannot read the \"\(list)\" list of Reminders: \(message)")
        }
        return output
    }
}
