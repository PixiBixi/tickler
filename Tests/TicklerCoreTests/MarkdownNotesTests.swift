import Testing
@testable import TicklerCore

struct MarkdownNotesTests {
    @Test func splitsBlocks() {
        let notes = """
        # Rollout

        1) Deploy **scaler** as is
        2. Check the series
        - dev first
          - then prod
        > do not enable prod profiles

        ```
        glab mr view 221
        ```
        Plain line with `code`.


        """
        #expect(MarkdownNotes.blocks(from: notes) == [
            .heading(level: 1, text: "Rollout"),
            .spacer,
            .numbered(marker: "1)", text: "Deploy **scaler** as is"),
            .numbered(marker: "2.", text: "Check the series"),
            .bullet(text: "dev first", depth: 0),
            .bullet(text: "then prod", depth: 1),
            .quote("do not enable prod profiles"),
            .spacer,
            .code("glab mr view 221"),
            .paragraph("Plain line with `code`."),
        ])
    }

    @Test func unclosedCodeFenceKeepsItsLines() {
        #expect(MarkdownNotes.blocks(from: "```\nsudo lsmp -v") == [.code("sudo lsmp -v")])
    }

    @Test func autolinksBareURLsWithTheirShortName() {
        let text = "See https://acme.atlassian.net/browse/OPS-2246, then (https://gitlab.com/acme/app/-/merge_requests/1060)."
        #expect(MarkdownNotes.autolink(text)
            ==
            "See [OPS-2246](https://acme.atlassian.net/browse/OPS-2246), then ([app !1060](https://gitlab.com/acme/app/-/merge_requests/1060)).")
    }

    @Test func leavesMarkdownLinksAlone() {
        let text = "[the MR](https://gitlab.com/acme/app/-/merge_requests/3) and <https://example.org>"
        #expect(MarkdownNotes.autolink(text) == text)
    }
}
