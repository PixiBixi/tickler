import Foundation
import TicklerCore

/// Live MR, ticket and PR status, kept in memory by URL. Nothing of it goes to the database.
@MainActor
@Observable
final class LiveStatusStore {
    struct Entry {
        var status: LiveStatus?
        var error: String?
        var fetchedAt: Date?
        var loading = false
    }

    /// Data younger than this is shown as is when a reminder is selected again.
    static let freshness: TimeInterval = 120

    private(set) var entries: [String: Entry] = [:]
    private let fetcher = LiveStatusFetcher(runner: LoginShellRunner())

    func supported(_ links: [ReminderLink]) -> [ReminderLink] {
        links.filter { LiveTarget(link: $0) != nil }
    }

    func refresh(_ links: [ReminderLink], force: Bool = false) {
        for link in supported(links) {
            let entry = entries[link.url] ?? Entry()
            if entry.loading {
                continue
            }
            if !force, let fetchedAt = entry.fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.freshness {
                continue
            }
            load(link)
        }
    }

    /// Returns whether GitLab accepted the approval; the card refreshes either way.
    func approve(_ link: ReminderLink) async -> Result<Void, Error> {
        guard let target = LiveTarget(link: link) else { return .failure(LiveError.unsupported) }
        do {
            try await fetcher.approve(target)
            load(link)
            return .success(())
        } catch {
            load(link)
            return .failure(error)
        }
    }

    private func load(_ link: ReminderLink) {
        guard let target = LiveTarget(link: link) else { return }
        entries[link.url, default: Entry()].loading = true
        Task {
            var entry = entries[link.url] ?? Entry()
            do {
                entry.status = try await fetcher.fetch(target)
                entry.error = nil
            } catch {
                entry.error = String(describing: error)
            }
            entry.fetchedAt = Date()
            entry.loading = false
            entries[link.url] = entry
        }
    }
}
