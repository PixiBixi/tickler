import Foundation

public enum LinkKind: String, Codable, Sendable, CaseIterable {
    case gitlabMR
    case jira
    case grafana
    case slack
    case githubPR
    case other
}

/// Finds URLs in free text and names them the way a person would ("prober !221", "OPS-2204").
public enum LinkExtractor {
    private static let trailing = CharacterSet(charactersIn: ").,;:!?'\"»]")

    public static func extract(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var urls: [URL] = []
        for match in detector.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let raw = String(text[swiftRange]).trimmingCharacters(in: trailing)
            guard raw.hasPrefix("http://") || raw.hasPrefix("https://"), let url = URL(string: raw) else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    public static func classify(_ url: URL) -> (kind: LinkKind, label: String) {
        let host = url.host() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }

        if let index = parts.firstIndex(of: "merge_requests"), index + 1 < parts.count, parts.contains("-") {
            let repo = parts.firstIndex(of: "-").flatMap { $0 > 0 ? parts[$0 - 1] : nil } ?? host
            return (.gitlabMR, "\(repo) !\(parts[index + 1])")
        }
        if let index = parts.firstIndex(of: "browse"), index + 1 < parts.count, host.hasSuffix("atlassian.net") || parts.count == 2 {
            return (.jira, parts[index + 1])
        }
        if host.hasSuffix("slack.com"), parts.first == "archives" {
            return (.slack, "Slack thread")
        }
        if host == "github.com", parts.count >= 4, parts[2] == "pull" {
            return (.githubPR, "\(parts[1]) #\(parts[3])")
        }
        if host.contains("grafana"), parts.count >= 2, parts[0] == "d" {
            return (.grafana, parts[1])
        }
        return (.other, host)
    }

    /// Links of a reminder: those found in its notes first, then the explicit ones, each URL once.
    public static func links(reminderId: String, notes: String, explicit: [String]) -> [ReminderLink] {
        var urls = extract(from: notes)
        var seen = Set(urls.map(\.absoluteString))
        for raw in explicit {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls.enumerated().map { position, url in
            let (kind, label) = classify(url)
            return ReminderLink(reminderId: reminderId, position: position, url: url.absoluteString, kind: kind, label: label)
        }
    }

    /// Links left after the notes change: explicit ones stay, those found in the old notes go, the new notes' are added.
    public static func linksAfterNotesChange(
        reminderId: String, oldNotes: String, newNotes: String, current: [ReminderLink]
    ) -> [ReminderLink] {
        let fromOldNotes = Set(extract(from: oldNotes).map(\.absoluteString))
        let explicit = current.sorted { $0.position < $1.position }.map(\.url).filter { !fromOldNotes.contains($0) }
        return links(reminderId: reminderId, notes: newNotes, explicit: explicit)
    }
}
