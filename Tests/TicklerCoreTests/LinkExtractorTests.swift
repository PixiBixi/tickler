import Foundation
import Testing
@testable import TicklerCore

struct LinkExtractorTests {
    @Test(arguments: [
        (
            "https://gitlab.com/acme/platform/prober/-/merge_requests/221",
            LinkKind.gitlabMR, "prober !221"
        ),
        ("https://acme.atlassian.net/browse/OPS-2204", .jira, "OPS-2204"),
        (
            "https://acme.slack.com/archives/D0123456789/p1790000000000001?thread_ts=1790000000.000001&cid=D0123456789",
            .slack, "Slack thread"
        ),
        ("https://github.com/PixiBixi/gopen/pull/12", .githubPR, "gopen #12"),
        ("https://grafana.example.com/d/tempo-writes", .grafana, "tempo-writes"),
        ("https://grafana.example.com/d/rollout-readiness/some-slug?orgId=1", .grafana, "rollout-readiness"),
        ("https://artifacts.example.com/ops-2204/cto-dashboard-v0-mockup", .other, "artifacts.example.com"),
    ])
    func classify(url: String, kind: LinkKind, label: String) throws {
        let parsed = try #require(URL(string: url))
        let result = LinkExtractor.classify(parsed)
        #expect(result.kind == kind)
        #expect(result.label == label)
    }

    @Test func extractsURLsInOrderWithoutTrailingPunctuation() {
        let text = """
        1) Dash (https://grafana.example.com/d/abc). Voir aussi https://acme.atlassian.net/browse/OPS-1,
        puis https://gitlab.com/a/b/-/merge_requests/3; et https://acme.atlassian.net/browse/OPS-1 encore.
        """
        let urls = LinkExtractor.extract(from: text).map(\.absoluteString)
        #expect(urls == [
            "https://grafana.example.com/d/abc",
            "https://acme.atlassian.net/browse/OPS-1",
            "https://gitlab.com/a/b/-/merge_requests/3",
        ])
    }

    @Test func ignoresTextWithoutLinks() {
        #expect(LinkExtractor.extract(from: "sudo lsmp -v -p 1 > /tmp/x.txt").isEmpty)
    }

    @Test func buildLinksMergesNotesAndExplicitWithoutDuplicates() {
        let links = LinkExtractor.links(
            reminderId: "abc123",
            notes: "see https://acme.atlassian.net/browse/OPS-9",
            explicit: ["https://acme.atlassian.net/browse/OPS-9", "https://github.com/o/r/pull/1"]
        )
        #expect(links.map(\.label) == ["OPS-9", "r #1"])
        #expect(links.map(\.position) == [0, 1])
    }
}
