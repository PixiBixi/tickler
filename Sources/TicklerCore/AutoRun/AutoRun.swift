import Foundation
import GRDB

/// One background run of a reminder's resume prompt.
public struct AutoRun: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "run"

    public enum State: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case cancelled
        case skipped
    }

    public enum Verdict: String, Codable, Sendable {
        case ok
        case watch
        case ko // swiftlint:disable:this identifier_name
        case unknown
    }

    public var id: String
    public var reminderId: String
    /// The due date the run answers, so a rescheduled reminder runs again.
    public var forDueAt: Date
    public var sessionId: String?
    public var mode: AutoRunMode
    public var startedAt: Date
    public var endedAt: Date?
    public var state: State
    public var verdict: Verdict?
    public var headline: String?
    public var figures: [String]
    public var nextStep: String?
    public var output: String?
    public var error: String?
    public var denials: Int?
    public var costUsd: Double?
    public var durationMs: Int?

    public init(
        id: String, reminderId: String, forDueAt: Date, sessionId: String?, mode: AutoRunMode, startedAt: Date,
        endedAt: Date? = nil, state: State, verdict: Verdict? = nil, headline: String? = nil, figures: [String] = [],
        nextStep: String? = nil, output: String? = nil, error: String? = nil, denials: Int? = nil,
        costUsd: Double? = nil, durationMs: Int? = nil
    ) {
        self.id = id
        self.reminderId = reminderId
        self.forDueAt = forDueAt
        self.sessionId = sessionId
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.verdict = verdict
        self.headline = headline
        self.figures = figures
        self.nextStep = nextStep
        self.output = output
        self.error = error
        self.denials = denials
        self.costUsd = costUsd
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case id, reminderId, forDueAt, sessionId, mode, startedAt, endedAt, state, verdict, headline, figures
        case nextStep, output, error, denials, costUsd, durationMs
    }

    /// `figures` lives in one JSON text column.
    public init(row: Row) throws {
        let json: String = row["figures"] ?? "[]"
        let figures = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        self.init(
            id: row["id"], reminderId: row["reminderId"], forDueAt: row["forDueAt"], sessionId: row["sessionId"],
            mode: AutoRunMode(rawValue: row["mode"]) ?? .read, startedAt: row["startedAt"], endedAt: row["endedAt"],
            state: State(rawValue: row["state"]) ?? .failed,
            verdict: (row["verdict"] as String?).flatMap(Verdict.init), headline: row["headline"], figures: figures,
            nextStep: row["nextStep"], output: row["output"], error: row["error"], denials: row["denials"],
            costUsd: row["costUsd"], durationMs: row["durationMs"]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["reminderId"] = reminderId
        container["forDueAt"] = forDueAt
        container["sessionId"] = sessionId
        container["mode"] = mode.rawValue
        container["startedAt"] = startedAt
        container["endedAt"] = endedAt
        container["state"] = state.rawValue
        container["verdict"] = verdict?.rawValue
        container["headline"] = headline
        container["figures"] = try String(decoding: JSONEncoder().encode(figures), as: UTF8.self)
        container["nextStep"] = nextStep
        container["output"] = output
        container["error"] = error
        container["denials"] = denials
        container["costUsd"] = costUsd
        container["durationMs"] = durationMs
    }
}

/// What a finished background run reports, as parsed from its output.
public struct RunResult: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case succeeded
        case failed
        case cancelled
    }

    public var state: State
    public var verdict: AutoRun.Verdict?
    public var headline: String?
    public var figures: [String]
    public var nextStep: String?
    public var output: String?
    public var error: String?
    public var sessionId: String?
    public var denials: Int?
    public var costUsd: Double?
    public var durationMs: Int?

    public init(
        state: State, verdict: AutoRun.Verdict? = nil, headline: String? = nil, figures: [String] = [],
        nextStep: String? = nil, output: String? = nil, error: String? = nil, sessionId: String? = nil,
        denials: Int? = nil, costUsd: Double? = nil, durationMs: Int? = nil
    ) {
        self.state = state
        self.verdict = verdict
        self.headline = headline
        self.figures = figures
        self.nextStep = nextStep
        self.output = output
        self.error = error
        self.sessionId = sessionId
        self.denials = denials
        self.costUsd = costUsd
        self.durationMs = durationMs
    }
}
