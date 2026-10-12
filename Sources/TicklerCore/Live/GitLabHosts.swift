import Foundation

/// The GitLab hosts glab holds a login for. A merge request link on any other host is never queried: glab would send it
/// a token (GITLAB_TOKEN overrides the per-host logins) and Tickler would act on whatever JSON it answered.
public enum GitLabHosts {
    public static let defaultHost = "gitlab.com"

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        var hosts: Set<String> = [defaultHost]
        if let host = environment["GITLAB_HOST"].flatMap(hostName) {
            hosts.insert(host)
        }
        if let text = try? String(contentsOf: configFile(environment: environment), encoding: .utf8) {
            hosts.formUnion(parse(text))
        }
        return hosts
    }

    /// glab's own lookup order: GLAB_CONFIG_DIR, then XDG_CONFIG_HOME, then ~/.config.
    static func configFile(environment: [String: String]) -> URL {
        if let directory = environment["GLAB_CONFIG_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory).appendingPathComponent("config.yml")
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("glab-cli/config.yml")
    }

    /// The keys directly under the top-level `hosts:` map of glab's config.yml.
    static func parse(_ yaml: String) -> Set<String> {
        var hosts: Set<String> = []
        var inHosts = false
        var childIndent: Int?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inHosts = trimmed == "hosts:"
                childIndent = nil
                continue
            }
            guard inHosts, trimmed.hasSuffix(":"), indent <= (childIndent ?? indent) else { continue }
            childIndent = indent
            let key = trimmed.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let host = hostName(key) {
                hosts.insert(host)
            }
        }
        return hosts
    }

    /// A bare host name, from either `gitlab.example.com` or `https://gitlab.example.com/`.
    static func hostName(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: value), let host = url.host() {
            value = host
        }
        return value.wholeMatch(of: /[a-z0-9.-]+/) != nil ? value : nil
    }
}
