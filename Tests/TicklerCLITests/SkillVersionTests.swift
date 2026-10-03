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
