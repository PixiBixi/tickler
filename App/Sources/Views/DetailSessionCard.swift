import SwiftUI
import TicklerCore

/// The Claude session behind a reminder: its state, what Resume will say (editable in place), and the buttons that act on it.
struct DetailSessionCard: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var editingPrompt = false

    static func isShown(_ reminder: Reminder, model: AppModel) -> Bool {
        reminder.sessionId != nil || reminder.fresh || model.autoRunner.isRunning(reminderId: reminder.id)
            || (reminder.status == .open && reminder.autoRunMode != nil)
    }

    private var autoRunning: Bool {
        model.autoRunner.isRunning(reminderId: reminder.id)
    }

    /// Resuming is refused while a background run holds the session.
    private var busy: Bool {
        autoRunning || reminder.continuedSessionId.map { model.autoRunner.runningSessions.contains($0) } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if autoRunning {
                AutoRunRunningRow(reminder: reminder)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    if !autoRunning {
                        statusLine
                    }
                    if reminder.canResume {
                        willSay
                    }
                }
                Spacer(minLength: 8)
                buttons
            }
            if editingPrompt {
                ResumePromptField(reminder: reminder)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: State

    private var statusLine: some View {
        let running = reminder.sessionId.map { model.runningSessions.contains($0) } ?? false
        // A finished background run says when it ran: a grey "Ended" read like a failure.
        let lastRun = running ? nil : model.finishedRun(for: reminder)
        return HStack(spacing: 8) {
            Circle().fill(running ? Color.green : (lastRun?.tint ?? Color.secondary.opacity(0.6))).frame(width: 7, height: 7)
            statusText(running: running, lastRun: lastRun)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(running ? .green : .secondary)
                .fixedSize()
            if let sessionId = reminder.sessionId {
                Text(verbatim: String(sessionId.prefix(8)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(sessionId)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func statusText(running: Bool, lastRun: AutoRun?) -> some View {
        if let ended = lastRun?.endedAt {
            Text("Last run · \(Format.relative(ended, now: model.now))")
        } else if running {
            Text("Running")
        } else if reminder.sessionId != nil {
            Text("Ended")
        } else if reminder.fresh {
            Label("Fresh session", systemImage: "sparkles")
                .help("Resume starts a new session in the folder with the prompt")
        } else {
            Text("No session yet")
        }
    }

    // MARK: Resume message

    private var willSay: some View {
        HStack(spacing: 6) {
            if let message = reminder.resumeMessage {
                Text("Will say: “\(message)”")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            } else {
                Text("No resume message").foregroundStyle(.secondary)
            }
            Button { editingPrompt.toggle() } label: {
                if editingPrompt {
                    Text("Done")
                } else if reminder.resumeMessage == nil {
                    Text("Add")
                } else {
                    Text("Edit")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel(Text("Edit the resume message"))
        }
        .font(.system(size: 13))
    }

    // MARK: Buttons

    private var ranOpen: Bool {
        reminder.status == .open && reminder.autoRunMode != nil && !autoRunning && model.hasRun(forCurrentDueDateOf: reminder)
    }

    private var runsNow: Bool {
        reminder.status == .open && reminder.autoRunMode != nil && !autoRunning && !model.hasRun(forCurrentDueDateOf: reminder)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if runsNow {
                Button { model.autoRunner.start(reminder) } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if ranOpen {
                Button { model.autoRunner.start(reminder) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Run again")
                    .accessibilityLabel(Text("Run again"))
            }
            if reminder.canResume {
                resumeButton
            }
        }
    }

    @ViewBuilder
    private var resumeButton: some View {
        let running = reminder.sessionId.map { model.runningSessions.contains($0) } ?? false
        let title: LocalizedStringKey = running ? "Show Tab" : (reminder.continuedSessionId == nil ? "Resume" : "Reopen")
        let button = Button { model.resume(reminder) } label: { Label(title, systemImage: "terminal") }
            .disabled(busy)
            .help(reminder.resumeMessage.map { "⌘R: \($0)" } ?? "⌘R")
        if runsNow {
            button.buttonStyle(SecondaryButtonStyle())
        } else {
            button.buttonStyle(PrimaryButtonStyle())
        }
    }
}
