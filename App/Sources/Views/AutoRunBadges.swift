import SwiftUI
import TicklerCore

extension AutoRun {
    /// The word shown for a finished run: the verdict when it answered, else how it ended.
    var statusLabel: String {
        switch state {
        case .running: String(localized: "Running")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .skipped: String(localized: "Skipped")
        case .succeeded: verdictLabel
        }
    }

    var verdictLabel: String {
        switch verdict ?? .unknown {
        case .ok: String(localized: "OK")
        case .watch: String(localized: "Needs a look")
        case .ko: String(localized: "KO")
        case .unknown: String(localized: "Unknown")
        }
    }

    var tint: Color {
        state == .succeeded ? Theme.verdict(verdict) : Theme.runNeutral
    }

    /// "7 min", from the stored duration or the two timestamps; nil while running.
    var durationText: String? {
        let seconds = durationMs.map { Double($0) / 1000 } ?? endedAt.map { $0.timeIntervalSince(startedAt) }
        return seconds.map { Format.elapsed(seconds: $0) }
    }

    /// "$0.84", only when the cost is known.
    var costText: String? {
        costUsd.map { String(format: "$%.2f", $0) }
    }
}

extension Format {
    /// "45 s" under a minute, else whole minutes.
    static func elapsed(seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? String(localized: "\(total) s") : String(localized: "\(total / 60) min")
    }
}

extension AppModel {
    /// The last run when it answers the reminder's current due date and is not in progress.
    func finishedRun(for reminder: Reminder) -> AutoRun? {
        guard reminder.status == .open, reminder.autoRunMode != nil, let run = lastRuns[reminder.id],
              run.state != .running, run.forDueAt == reminder.dueAt else { return nil }
        return run
    }

    /// One short line for the list and the menu bar: elapsed time while running, else the last outcome.
    func autoRunSummary(for reminder: Reminder) -> String? {
        if autoRunner.isRunning(reminderId: reminder.id) {
            let elapsed = autoRunner.startedAt(reminderId: reminder.id).map { Format.elapsed(seconds: now.timeIntervalSince($0)) }
            return String(localized: "Running · \(elapsed ?? "")")
        }
        guard let run = finishedRun(for: reminder) else { return nil }
        return run.state == .skipped ? String(localized: "Session open, start it manually") : run.statusLabel
    }
}

/// "AUTO · read only" next to the due date.
struct AutoRunPill: View {
    let mode: AutoRunMode

    var body: some View {
        Text(mode == .read ? "AUTO · read only" : "AUTO · can modify")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Replaces the due dot of an auto-run reminder: scheduled, spinner while running, the verdict colour once done.
struct AutoRunMark: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    let fallback: Color

    var body: some View {
        Group {
            if model.autoRunner.isRunning(reminderId: reminder.id) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            } else if let run = model.finishedRun(for: reminder) {
                Circle().fill(run.tint).frame(width: 8, height: 8)
            } else if reminder.status == .open, reminder.autoRunMode != nil {
                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
            } else {
                Circle().fill(fallback).frame(width: 8, height: 8)
            }
        }
        .frame(width: 8, height: 8)
    }
}
