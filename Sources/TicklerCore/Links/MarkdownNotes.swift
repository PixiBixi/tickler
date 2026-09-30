import Foundation

/// Notes are Markdown. This splits them into the blocks the app draws; inline syntax (bold, code, links)
/// is left to AttributedString. Bare URLs become named links first, so a raw GitLab URL reads "repo !221".
public enum MarkdownNotes {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(text: String, depth: Int)
        case numbered(marker: String, text: String)
        case code(String)
        case quote(String)
        case paragraph(String)
        case spacer
    }

    public static func blocks(from notes: String) -> [Block] {
        var blocks: [Block] = []
        var code: [String]?
        for raw in notes.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            blocks.append(block(for: raw))
        }
        if let lines = code {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        // Collapse runs of empty lines into one spacer, drop leading and trailing ones.
        var collapsed: [Block] = []
        for block in blocks where !(block == .spacer && (collapsed.isEmpty || collapsed.last == .spacer)) {
            collapsed.append(block)
        }
        while collapsed.last == .spacer {
            collapsed.removeLast()
        }
        return collapsed
    }

    private static func block(for raw: String) -> Block {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            return .spacer
        }
        if let match = line.wholeMatch(of: /(#{1,3})\s+(.+)/) {
            return .heading(level: match.1.count, text: String(match.2))
        }
        if let match = raw.wholeMatch(of: /(\s*)[-*+]\s+(.+)/) {
            return .bullet(text: String(match.2), depth: match.1.count / 2)
        }
        if let match = line.wholeMatch(of: /(\d{1,3}[.)])\s+(.+)/) {
            return .numbered(marker: String(match.1), text: String(match.2))
        }
        if let match = line.wholeMatch(of: />\s?(.*)/) {
            return .quote(String(match.1))
        }
        return .paragraph(line)
    }

    /// Wraps bare URLs as `[label](url)`; URLs already inside Markdown links or angle brackets stay as written.
    public static func autolink(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            var range = match.range
            // Trailing punctuation belongs to the sentence, not the URL.
            while range.length > 0, ").,;:!?".contains(nsText.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                range.length -= 1
            }
            let before = range.location >= 2 ? nsText.substring(with: NSRange(location: range.location - 2, length: 2)) : ""
            let previous = range.location >= 1 ? nsText.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            let raw = nsText.substring(with: range)
            guard raw.hasPrefix("http"), before != "](", previous != "<", previous != "[", let url = URL(string: raw) else { continue }
            result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let label = LinkExtractor.classify(url).label.replacingOccurrences(of: "]", with: "")
            result += "[\(label)](\(raw))"
            cursor = NSMaxRange(range)
        }
        result += nsText.substring(from: cursor)
        return result
    }
}
