import Foundation

/// Turns the output of `claude -p --output-format json` into a `RunResult`.
public enum AutoRunParser {
    private static let stderrLines = 20

    // swiftlint:disable:next large_tuple
    public typealias Report = (verdict: AutoRun.Verdict, headline: String?, figures: [String], nextStep: String?)

    public static func parse(stdout: Data, stderr: Data, status: Int32, timedOut: Bool, cancelled: Bool) -> RunResult {
        if cancelled {
            return RunResult(state: .cancelled, error: "Stopped")
        }
        if timedOut {
            return failure("Timed out after 30 min", stderr: stderr)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else {
            return failure(status == 0 ? "Unreadable claude output" : "claude exited with status \(status)", stderr: stderr)
        }
        let text = object["result"] as? String
        let denials = (object["permission_denials"] as? [Any])?.count
        let sessionId = object["session_id"] as? String
        let cost = (object["total_cost_usd"] as? NSNumber)?.doubleValue
        let duration = (object["duration_ms"] as? NSNumber)?.intValue
        var result = RunResult(
            state: .succeeded, output: text, sessionId: sessionId, denials: denials, costUsd: cost, durationMs: duration
        )
        if object["is_error"] as? Bool == true || status != 0 {
            let message = status != 0 && object["is_error"] as? Bool != true
                ? "claude exited with status \(status)" : "claude reported an error"
            result.state = .failed
            result.error = withStderr(message, stderr: stderr)
            return result
        }
        let report = report(in: text ?? "")
        result.verdict = report.verdict
        result.headline = report.headline
        result.figures = report.figures
        result.nextStep = report.nextStep
        return result
    }

    /// Reads from the last `Verdict:` line; without one the verdict is unknown and the headline the first line.
    public static func report(in text: String) -> Report {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(where: { value(of: "verdict:", in: $0) != nil }),
              let rest = value(of: "verdict:", in: lines[start])
        else {
            return (.unknown, lines.first { !$0.isEmpty }, [], nil)
        }
        let (word, headline) = split(rest)
        var figures: [String] = []
        var nextStep: String?
        var inFigures = false
        for line in lines[(start + 1)...] {
            if value(of: "key figures:", in: line) != nil {
                inFigures = true
            } else if let next = value(of: "next step:", in: line) {
                inFigures = false
                nextStep = next.isEmpty || next.lowercased() == "none" ? nil : next
            } else if inFigures, line.hasPrefix("- ") {
                figures.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !line.isEmpty {
                inFigures = false
            }
        }
        return (AutoRun.Verdict(rawValue: word.lowercased()) ?? .unknown, headline, figures, nextStep)
    }

    /// The text after `key` when the line starts with it, ignoring case and leading `**` or `-`.
    private static func value(of key: String, in line: String) -> String? {
        var text = Substring(line)
        while let first = text.first, first == "*" || first == "-" || first == " " {
            text = text.dropFirst()
        }
        guard text.lowercased().hasPrefix(key) else { return nil }
        return clean(String(text.dropFirst(key.count)))
    }

    private static func split(_ rest: String) -> (word: String, headline: String?) {
        if let range = rest.range(of: " - ") {
            let headline = clean(String(rest[range.upperBound...]))
            return (clean(String(rest[..<range.lowerBound])), headline.isEmpty ? nil : headline)
        }
        let word = rest.split(whereSeparator: { $0 == ":" || $0 == " " }).first.map(String.init) ?? ""
        return (clean(word), nil)
    }

    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix("*") {
            value.removeLast()
        }
        while value.hasPrefix("*") {
            value.removeFirst()
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func failure(_ message: String, stderr: Data) -> RunResult {
        RunResult(state: .failed, error: withStderr(message, stderr: stderr))
    }

    private static func withStderr(_ message: String, stderr: Data) -> String {
        let tail = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline).suffix(stderrLines).joined(separator: "\n")
        return tail.isEmpty ? message : message + "\n" + tail
    }
}
