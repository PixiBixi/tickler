import Foundation

/// The footer the old reminders skill appended to Apple Reminders notes: session id and a resume command.
public enum AppleReminderFooter {
    public struct Parsed: Equatable, Sendable {
        public var notes: String
        public var sessionId: String?
        public var cwd: String?
    }

    /// Regex values are not Sendable in Swift 6: literals live in functions instead of static lets.
    private static func sessionValue(_ line: String) -> String? {
        line.wholeMatch(of: /^\s*Session Claude\s*:\s*(\S+)\s*$/).map { String($0.1) }
    }

    private static func resumeValue(_ line: String) -> String? {
        line.wholeMatch(of: /^\s*Reprendre\s*:\s*(.*)$/).map { String($0.1) }
    }

    private static func uuidRange(in text: String) -> Range<String.Index>? {
        text.firstMatch(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/)?.range
    }

    /// A truncated display id yields no session id: resuming needs the full one, which only the Reprendre line may carry.
    public static func parse(notes: String) -> Parsed {
        let lines = notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard let start = lines.firstIndex(where: { sessionValue($0) != nil || resumeValue($0) != nil }) else {
            return Parsed(notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), sessionId: nil, cwd: nil)
        }
        var sessionId: String?
        var cwd: String?
        for line in lines[start...] {
            if let value = sessionValue(line) {
                sessionId = fullUUID(in: value) ?? sessionId
            } else if let command = resumeValue(line) {
                sessionId = fullUUID(in: command) ?? sessionId
                cwd = folder(in: command) ?? cwd
            }
        }
        let body = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(notes: body, sessionId: sessionId, cwd: cwd)
    }

    private static func fullUUID(in text: String) -> String? {
        uuidRange(in: text).map { String(text[$0]).lowercased() }
    }

    /// What follows the session id on the command line: quoted, or bare; `~` is expanded.
    private static func folder(in command: String) -> String? {
        guard let id = uuidRange(in: command) else { return nil }
        var rest = String(command[id.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let quote = rest.first, quote == "'" || quote == "\"" {
            rest.removeFirst()
            if let end = rest.firstIndex(of: quote) {
                rest = String(rest[..<end])
            }
        }
        guard !rest.isEmpty else { return nil }
        return (rest as NSString).expandingTildeInPath
    }
}
