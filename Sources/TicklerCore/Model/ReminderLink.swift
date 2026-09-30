import Foundation
import GRDB

public struct ReminderLink: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "link"

    public var reminderId: String
    public var position: Int
    public var url: String
    public var kind: LinkKind
    public var label: String

    public init(reminderId: String, position: Int, url: String, kind: LinkKind, label: String) {
        self.reminderId = reminderId
        self.position = position
        self.url = url
        self.kind = kind
        self.label = label
    }
}
