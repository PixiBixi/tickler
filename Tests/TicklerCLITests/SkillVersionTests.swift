import Foundation
import Testing
@testable import TicklerCLI
@testable import TicklerCore

struct SkillVersionTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")

    func cli() -> CLIHarness {
        var cli = CLIHarness()
        cli.environment = ["HOME": home.path]
        return cli
    }

    var skillFile: URL {
        home.appendingPathComponent(".claude/skills/tickler/SKILL.md")
    }

    @Test func versionIsPrinted() {
        #expect(cli().run("version").out == "tickler \(Tickler.version)\n")
    }

    @Test func installThenUpToDate() throws {
        let cli = cli()
        #expect(cli.run("skill", "status").out.hasPrefix("not installed\t"))
        #expect(cli.run("skill", "install").out == "installed\t\(skillFile.path)\n")
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == ClaudeSkill.content)
        #expect(cli.run("skill", "install").out.hasPrefix("up to date\t"))
        #expect(cli.run("skill", "status").out.hasPrefix("up to date\t"))
    }

    @Test func anEditedSkillIsOnlyReplacedWithForce() throws {
        let cli = cli()
        _ = cli.run("skill", "install")
        try "my edits\n".write(to: skillFile, atomically: true, encoding: .utf8)
        let refused = cli.run("skill", "install")
        #expect(refused.code == 1)
        #expect(refused.err.contains("--force"))
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == "my edits\n")
        #expect(cli.run("skill", "install", "--force").out.hasPrefix("replaced\t"))
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == ClaudeSkill.content)
    }

    @Test func aSymlinkedSkillFileKeepsItsLink() throws {
        let cli = cli()
        let target = home.appendingPathComponent("dotfiles/SKILL.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "older skill\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillFile, withDestinationURL: target)
        try (ClaudeSkill.hash("older skill\n") + "\n").write(
            to: skillFile.deletingLastPathComponent().appendingPathComponent(".tickler-installed"), atomically: true, encoding: .utf8
        )
        #expect(cli.run("skill", "install").out.hasPrefix("updated\t"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skillFile.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == ClaudeSkill.content)
    }

    @Test func aDanglingSkillSymlinkIsRefused() throws {
        let cli = cli()
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: skillFile.path, withDestinationPath: "missing.md")
        let result = cli.run("skill", "install", "--force")
        #expect(result.code == 1)
        #expect(result.err.contains("symlink to a missing file"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skillFile.path) == "missing.md")
        #expect(!FileManager.default.fileExists(atPath: skillFile.deletingLastPathComponent().appendingPathComponent("missing.md").path))
    }

    @Test func anUntouchedOlderSkillIsUpdatedWithoutForce() throws {
        let cli = cli()
        _ = cli.run("skill", "install")
        // What an older Tickler would have left: its own content and the matching stamp.
        let older = "older skill\n"
        try older.write(to: skillFile, atomically: true, encoding: .utf8)
        try (ClaudeSkill.hash(older) + "\n").write(
            to: skillFile.deletingLastPathComponent().appendingPathComponent(".tickler-installed"), atomically: true, encoding: .utf8
        )
        #expect(cli.run("skill", "status").out.hasPrefix("outdated"))
        #expect(cli.run("skill", "install").out.hasPrefix("updated\t"))
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == ClaudeSkill.content)
    }

    @Test func claudeConfigDirIsHonored() {
        let custom = home.appendingPathComponent("custom")
        #expect(ClaudeSkill.directory(environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": custom.path]).path
            == custom.appendingPathComponent("skills/tickler").path)
    }

    /// The CLI and the app install the embedded copy: it must match the file in the repository.
    @Test func embeddedSkillMatchesTheRepository() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("skills/tickler/SKILL.md")
        #expect(try String(contentsOf: source, encoding: .utf8) == ClaudeSkill.content, "run scripts/embed-skill.sh")
    }
}
