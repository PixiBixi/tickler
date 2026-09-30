import Foundation
import Testing
@testable import TicklerCLI
import TicklerCore

struct StatusTests {
    @Test func reportsEachSupportedLinkAndKeepsGoingOnErrors() throws {
        var cli = CLIHarness()
        cli.liveRunner = StubRunner(
            responses: [
                "merge_requests/3": #"{"iid":3,"title":"t","state":"opened","draft":false,"detailed_merge_status":"not_approved","has_conflicts":false,"blocking_discussions_resolved":true,"web_url":"u","author":{"username":"a"},"head_pipeline":{"status":"success","web_url":"p"}}"#,
                "merge_requests/3/approvals": #"{"approvals_required":1,"approvals_left":1,"user_has_approved":false,"user_can_approve":true,"approved_by":[]}"#,
            ],
            failing: ["jira"]
        )
        let notes = "https://gitlab.com/acme/app/-/merge_requests/3 https://acme.atlassian.net/browse/OPS-1 https://grafana.example.org/d/x"
        let add = cli.run("add", "t", "--at", "2026-10-01 12:00", "--notes", notes)
        let id = try #require(add.out.split(separator: "\t").first.map(String.init))

        let text = cli.run("status", id)
        #expect(text.code == 0)
        #expect(text.out.contains("app !3  opened, pipeline success, approvals 0/1, you can approve"))
        #expect(text.out.contains("OPS-1  error: jira: not logged in"))

        let json = try cli.run("status", id, "--json").jsonArray()
        #expect(json.count == 2)
        #expect((json[0]["mergeRequest"] as? [String: Any])?["userCanApprove"] as? Bool == true)
    }

    @Test func unknownIdExitsThree() {
        #expect(CLIHarness().run("status", "zzzzzz").code == 3)
    }
}
