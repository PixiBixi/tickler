import Foundation
import Testing
@testable import TicklerCore

struct ToolCheckTests {
    @Test func installUsesTheHomebrewFormulaNames() {
        #expect(ToolCheck.installArguments(for: [.glab, .jira, .gh]) == ["install", "glab", "jira-cli", "gh"])
    }

    @Test func locatesAToolThroughTheLoginShell() async {
        #expect(await ToolCheck.locate(.gh, shell: "/bin/zsh") != nil || !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/gh"))
    }

    @Test func loginCommands() {
        #expect(ExternalTool.allCases.map(\.loginCommand) == ["glab auth login", "jira init", "gh auth login"])
    }

    @Test func eachTargetNamesItsTool() {
        #expect(LiveTarget.gitlabMR(host: "gitlab.com", project: "a/b", iid: 1).tool == .glab)
        #expect(LiveTarget.jira(key: "OPS-1").tool == .jira)
        #expect(LiveTarget.githubPR(owner: "o", repo: "r", number: 1).tool == .gh)
    }
}
