import Foundation
import Security

/// The Jira API token, kept in the login keychain under Tickler's own entry: only this app reads it, without a prompt.
/// jira gets it as JIRA_API_TOKEN for the one command, so neither the shell profile nor ~/.netrc is needed.
enum JiraToken {
    private static let service = "io.github.pixibixi.tickler.jira"
    private static let account = "api-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var isSet: Bool {
        read() != nil
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Tickler: Jira API token"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// Environment for the app's tool runner.
    @Sendable static func environment(for tool: String) -> [String: String] {
        guard tool == "jira", let token = read() else { return [:] }
        return ["JIRA_API_TOKEN": token]
    }
}
