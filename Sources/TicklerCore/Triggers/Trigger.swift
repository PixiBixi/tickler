import Foundation

/// An event on a reminder's links that makes it due now. Stored as typed: `merged`, `jira:In Review`.
public enum Trigger: Hashable, Sendable {
    case merged
    case pipelineGreen
    case pipelineFailed
    case approved
    /// Status category Done, whatever the workflow calls it.
    case jiraDone
    /// Exact status name, compared case-insensitively.
    case jiraStatus(String)

    public static let usage = "merged, pipeline-green, pipeline-failed, approved, jira:done or jira:<status>"

    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.contains(where: \.isNewline) else { return nil }
        switch text.lowercased() {
        case "merged": self = .merged
        case "pipeline-green": self = .pipelineGreen
        case "pipeline-failed": self = .pipelineFailed
        case "approved": self = .approved
        default:
            guard text.lowercased().hasPrefix("jira:") else { return nil }
            let name = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = name.lowercased() == "done" ? .jiraDone : .jiraStatus(name)
        }
    }

    public var rawValue: String {
        switch self {
        case .merged: "merged"
        case .pipelineGreen: "pipeline-green"
        case .pipelineFailed: "pipeline-failed"
        case .approved: "approved"
        case .jiraDone: "jira:done"
        case let .jiraStatus(name): "jira:\(name)"
        }
    }

    public func supports(_ kind: LinkKind) -> Bool {
        switch self {
        case .merged, .pipelineGreen, .pipelineFailed, .approved: kind == .gitlabMR || kind == .githubPR
        case .jiraDone, .jiraStatus: kind == .jira
        }
    }

    /// The fallback deadline when none is given: 3 working days later, at the working start.
    public static func defaultDeadline(after now: Date, calendar: Calendar, schedule: WorkSchedule = .standard) -> Date {
        if let date = WorkingTime(schedule: schedule, calendar: calendar).addingWorkingDays(3, to: now) {
            return date
        }
        // No working day in the settings: three plain days later at the start time.
        let day = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now)) ?? now
        return WorkingTime(schedule: schedule, calendar: calendar).date(schedule.start, on: day) ?? day
    }
}
