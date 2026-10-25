import SwiftUI
import TicklerCore

/// "Result": the verdict, key figures, next step and the full answer folded, tinted by verdict.
struct AutoRunResultBlock: View {
    let run: AutoRun
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if run.state == .skipped {
                Text("Session open, start it manually").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                verdictLine
                figures
                nextStep
                denials
                fullAnswer
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(run.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(run.tint.opacity(0.35)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// "10:00 → 10:07 · 7 min · $0.84", led by the day when the run did not end today.
    private var meta: String {
        var parts = [Format.time(run.startedAt)]
        if !Calendar.current.isDateInToday(run.endedAt ?? run.startedAt) {
            parts[0] = (run.endedAt ?? run.startedAt).formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
                .locale(Format.locale)) + " " + parts[0]
        }
        if let ended = run.endedAt {
            parts[0] += " → " + Format.time(ended)
        }
        parts.append(contentsOf: [run.durationText, run.costText].compactMap(\.self))
        return parts.joined(separator: " · ")
    }

    private var verdictLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(run.statusLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(run.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(run.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            if let text = run.headline ?? run.error {
                Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(run.headline == nil ? 3 : 1)
                    .help(text)
            }
        }
    }

    @ViewBuilder
    private var figures: some View {
        if !run.figures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                label("Key figures")
                ForEach(Array(run.figures.enumerated()), id: \.offset) { _, figure in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(verbatim: figure).font(.system(size: 12.5)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nextStep: some View {
        if let step = run.nextStep, !step.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                label("Next step")
                Text(verbatim: step).font(.system(size: 12.5)).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var denials: some View {
        if let count = run.denials, count > 0 {
            Label("\(count) actions denied", systemImage: "hand.raised")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.verdictWatch)
        }
    }

    @ViewBuilder
    private var fullAnswer: some View {
        if let output = run.output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
            VStack(alignment: .leading, spacing: 0) {
                // A plain DisclosureGroup only reacts on its chevron on macOS: the whole row toggles here.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Full answer (\(lines) lines)").font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    MarkdownView(markdown: output)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// "Running · 4 min" and Stop, in the session panel while a background run is in progress.
struct AutoRunRunningRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14)
            // Refreshes every second only while the row is on screen.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Running · \(elapsed(at: context.date))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .monospacedDigit()
            }
            if let session = reminder.sessionId {
                Text(verbatim: session)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { model.autoRunner.stop(reminderId: reminder.id) } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func elapsed(at date: Date) -> String {
        let start = model.autoRunner.startedAt(reminderId: reminder.id) ?? date
        return Format.elapsed(seconds: date.timeIntervalSince(start))
    }
}

/// "Runs": the history of this reminder, newest first.
struct AutoRunRunsList: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var runs: [AutoRun] = []

    var body: some View {
        Group {
            // One run is already the result block above.
            if runs.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(runs.prefix(10)) { run in
                        HStack(spacing: 6) {
                            Circle().fill(run.tint).frame(width: 7, height: 7)
                            Text(verbatim: Format.dueLabel(run.startedAt, now: model.now))
                            Text("·").foregroundStyle(.tertiary)
                            Text(run.statusLabel).foregroundStyle(run.tint)
                            if let duration = run.durationText {
                                Text("·").foregroundStyle(.tertiary)
                                Text(verbatim: duration).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                    }
                }
            }
        }
        .task(id: signature) { runs = (try? model.store?.runs(for: reminder.id)) ?? [] }
    }

    /// Reloads when a run starts or ends.
    private var signature: String {
        let last = model.lastRuns[reminder.id]
        return "\(last?.id ?? "")\(last?.state.rawValue ?? "")"
    }
}
