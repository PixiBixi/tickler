import Foundation
import Security

/// The Jira API token, kept in the login keychain under Tickler's own entry: only this app reads it, without a prompt
/// while it keeps the signing identity that saved it; another identity gets a macOS prompt.
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

    enum State: Equatable {
        case saved
        case missing
        /// The keychain refused: prompt denied, keychain locked. Not the same as no token.
        case unreadable(String)
    }

    /// Whether the entry exists, from its attributes only: the secret is not fetched, so no access prompt.
    static func state() -> State {
        var search = query
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .saved
        case errSecItemNotFound: return .missing
        default: return .unreadable(message(for: status))
        }
    }

    /// `state()` off the main actor: securityd can stall, and a stall there freezes the UI.
    static func loadState() async -> State {
        await Task.detached { state() }.value
    }

    static var isSet: Bool {
        state() == .saved
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
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message(for: status)])
        }
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    /// Environment for the app's tool runner.
    @Sendable static func environment(for tool: String) -> [String: String] {
        guard tool == "jira", let token = read() else { return [:] }
        return ["JIRA_API_TOKEN": token]
    }
}
