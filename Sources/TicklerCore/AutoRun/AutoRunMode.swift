import Foundation

/// How much a background run may do: `read` answers and looks, `write` may also edit files.
public enum AutoRunMode: String, Codable, Sendable, CaseIterable {
    case read
    case write

    /// The value of `claude --permission-mode`.
    public var permissionMode: String {
        switch self {
        case .read: "dontAsk"
        case .write: "acceptEdits"
        }
    }
}
