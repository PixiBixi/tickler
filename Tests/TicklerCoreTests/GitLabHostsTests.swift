import Foundation
import Testing
@testable import TicklerCore

struct GitLabHostsTests {
    @Test func readsTheHostsGlabIsLoggedInTo() {
        let config = """
        git_protocol: ssh
        host: gitlab.com
        hosts:
            gitlab.com:
                api_protocol: https
                token: secret
                user: alice
            gitlab.example.org:
                api_host: gitlab.example.org
                container_registry_domains: gitlab.example.org,registry.example.org
        last_seen_version: v1.122.0
        """
        #expect(GitLabHosts.parse(config) == ["gitlab.com", "gitlab.example.org"])
    }

    @Test func ignoresKeysOutsideTheHostsMap() {
        #expect(GitLabHosts.parse("aliases:\n    co:\n        x: y\nhost: evil.example\n").isEmpty)
    }

    @Test func alwaysKnowsGitLabDotComAndTheEnvironmentHost() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hosts:\n    git.corp.example:\n        token: x\n".write(
            to: directory.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8
        )
        let hosts = GitLabHosts.current(environment: ["GLAB_CONFIG_DIR": directory.path, "GITLAB_HOST": "https://gitlab.other.example/"])
        #expect(hosts == ["gitlab.com", "git.corp.example", "gitlab.other.example"])
    }

    @Test func aMissingConfigLeavesOnlyGitLabDotCom() {
        #expect(GitLabHosts.current(environment: ["GLAB_CONFIG_DIR": "/nonexistent/glab"]) == ["gitlab.com"])
    }
}
