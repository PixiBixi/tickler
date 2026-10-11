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
    /// Bumped by every fetch and by `forgetTickets`: a fetch writes back only if nothing started or reset since,
    /// or an answer to an old token would overwrite the new one's for the whole freshness window.
    private var generations: [String: Int] = [:]
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
        let forgotten = entries.filter { _, entry in
            if case .ticket = entry.status {
                return true
            }
            return entry.error != nil
        }
        for url in forgotten.keys {
            entries[url] = nil
            nextGeneration(url)
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
        var started: [String: Int] = [:]
        for link in supported(links) {
            targets[link.url] = LiveTarget(link: link)
            started[link.url] = nextGeneration(link.url)
        }
        let fetcher = fetcher
        // Not a TaskGroup: on macOS 26 the group was freed while a child still ran (SIGSEGV in TaskGroup::offer,
        // crash loop at launch with several waiting MRs). Do not switch back without reproducing that case.
        let tasks = targets.map { url, target in
            (url, Task.detached { () -> Result<LiveStatus, Error> in
                do {
                    return try await .success(fetcher.fetch(target))
                } catch {
                    return .failure(error)
                }
            })
        }
        var results: [String: Result<LiveStatus, Error>] = [:]
        for (url, task) in tasks {
            results[url] = await task.value
        }
        var statuses: [String: LiveStatus] = [:]
        for (url, result) in results {
            if case let .success(status) = result {
                statuses[url] = status
            }
            if let generation = started[url] {
                store(result, for: url, generation: generation)
            }
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
        let generation = nextGeneration(link.url)
        let fetcher = fetcher
        Task {
            let result: Result<LiveStatus, Error>
            do {
                result = try await .success(fetcher.fetch(target))
            } catch {
                result = .failure(error)
            }
            store(result, for: link.url, generation: generation)
        }
    }

    @discardableResult
    private func nextGeneration(_ url: String) -> Int {
        let next = (generations[url] ?? 0) + 1
        generations[url] = next
        return next
    }

    /// Reads the entry after the fetch, not before: a stale copy would undo what changed meanwhile.
    private func store(_ result: Result<LiveStatus, Error>, for url: String, generation: Int) {
        guard generations[url] == generation else { return }
        var entry = entries[url] ?? Entry()
        switch result {
        case let .success(status):
            entry.status = status
            entry.error = nil
        case let .failure(error):
            entry.error = String(describing: error)
        }
        entry.fetchedAt = Date()
        entry.loading = false
        entries[url] = entry
    }
}
