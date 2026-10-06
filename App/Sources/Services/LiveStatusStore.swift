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
    private let runner = AppToolRunner(environment: JiraToken.environment(for:))
    private var fetcher: LiveStatusFetcher {
        LiveStatusFetcher(runner: runner)
    }

    /// Checks the Jira login with `jira me`: the account name on success.
    func testJira() async -> Result<String, Error> {
        do {
            let output = try await runner.run("jira", ["me"])
            return .success(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(error)
        }
    }

    /// A new token must not wait for the 2 minute freshness: drop what Jira answered so far.
    func forgetTickets() {
        entries = entries.filter { _, entry in
            if case .ticket = entry.status {
                return false
            }
            return entry.error == nil
        }
    }

    /// Links whose tool the user enabled.
    func supported(_ links: [ReminderLink]) -> [ReminderLink] {
        let enabled = AppModel.shared.preferences.enabledTools
        return links.filter { LiveTarget(link: $0).map { enabled.contains($0.tool) } ?? false }
    }

    /// Demo recordings show fixed statuses instead of calling glab, jira or gh.
    func setDemoStatus(_ status: LiveStatus, for url: String) {
        entries[url] = Entry(status: status, error: nil, fetchedAt: Date(), loading: false)
    }

    func refresh(_ links: [ReminderLink], force: Bool = false) {
        if AppModel.shared.isDemo {
            return
        }
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

    /// The statuses of `links` when every one is loaded and finished; nil while something is open, unknown or failing.
    func allFinished(_ links: [ReminderLink]) -> [LiveStatus]? {
        let tracked = supported(links)
        guard !tracked.isEmpty else { return nil }
        let statuses = tracked.compactMap { entries[$0.url]?.status }
        guard statuses.count == tracked.count, statuses.allSatisfy(\.isFinished) else { return nil }
        return statuses
    }

    /// Fetches every supported link now, in parallel, updates the cards, and returns what answered, by URL.
    func fetchNow(_ links: [ReminderLink]) async -> [String: LiveStatus] {
        var targets: [String: LiveTarget] = [:]
        for link in supported(links) {
            targets[link.url] = LiveTarget(link: link)
        }
        let fetcher = fetcher
        let results = await withTaskGroup(of: (String, Result<LiveStatus, Error>).self) { group in
            for (url, target) in targets {
                group.addTask {
                    do {
                        return try await (url, .success(fetcher.fetch(target)))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }
            var collected: [String: Result<LiveStatus, Error>] = [:]
            for await (url, result) in group {
                collected[url] = result
            }
            return collected
        }
        var statuses: [String: LiveStatus] = [:]
        for (url, result) in results {
            var entry = entries[url] ?? Entry()
            switch result {
            case let .success(status):
                entry.status = status
                entry.error = nil
                statuses[url] = status
            case let .failure(error):
                entry.error = String(describing: error)
            }
            entry.fetchedAt = Date()
            entries[url] = entry
        }
        return statuses
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

    func merge(_ link: ReminderLink, whenPipelinePasses: Bool) async -> Result<Void, Error> {
        guard let target = LiveTarget(link: link) else { return .failure(LiveError.unsupported) }
        do {
            try await fetcher.merge(target, whenPipelinePasses: whenPipelinePasses)
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
