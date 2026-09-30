import Foundation
import Testing
@testable import TicklerCore

struct ToolCheckTests {
    @Test func installUsesTheHomebrewFormulaNames() {
        #expect(ToolCheck.installArguments(for: [.glab, .jira, .gh]) == ["install", "glab", "jira-cli", "gh"])
    }

    @Test func locatesToolsOnDisk() {
        #expect((ToolCheck.locate(.gh) != nil) == FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh"))
    }

    @Test func onlyJiraNeedsTheShell() {
        #expect(AppToolRunner.needsShell("jira"))
        #expect(!AppToolRunner.needsShell("glab"))
        #expect(!AppToolRunner.needsShell("gh"))
    }

    @Test func loginCommands() {
        #expect(ExternalTool.allCases.map(\.loginCommand) == ["glab auth login", "jira init", "gh auth login"])
    }

    @Test func eachTargetNamesItsTool() {
        #expect(LiveTarget.gitlabMR(host: "gitlab.com", project: "a/b", iid: 1).tool == .glab)
        #expect(LiveTarget.jira(key: "OPS-1").tool == .jira)
        #expect(LiveTarget.githubPR(owner: "o", repo: "r", number: 1).tool == .gh)
    }

    @Test func versionComesFromTheCellarPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-\(UUID().uuidString)")
        let real = root.appendingPathComponent("Cellar/gh/2.97.0/bin/gh")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: real.path, contents: Data())
        let link = root.appendingPathComponent("bin/gh")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ToolCheck.version(of: link.path) == "2.97.0")
        #expect(ToolCheck.version(of: "/bin/ls") == nil)
    }
}
