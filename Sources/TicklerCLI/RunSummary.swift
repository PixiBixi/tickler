import Foundation
import TicklerCore

/// The last background run as `show` prints it. Everything Claude wrote goes through the display sanitising.
struct RunSummary {
    let run: AutoRun
    let calendar: Calendar

    /// `Last run: <state> <verdict> <date>`
    var title: String {
        let verdict = run.verdict.map { " \($0.rawValue)" } ?? ""
        return "Last run: \(run.state.rawValue)\(verdict) \(StrictDate.format(run.startedAt, calendar: calendar))"
    }

    /// Headline, figures, next step and, for a run that did not finish well, its error.
    var body: [String] {
        var lines: [String] = []
        if let headline = run.headline {
            lines.append(headline.displaySafeLine)
        }
        lines += run.figures.map { "- \($0.displaySafeLine)" }
        if let nextStep = run.nextStep {
            lines.append("next: \(nextStep.displaySafeLine)")
        }
        if let error = run.error {
            lines.append("error: \(error.displaySafeLine)")
        }
        return lines
    }

    var lines: [String] {
        [title] + body.map { "  \($0)" }
    }
}
