import SwiftUI
import TicklerCore

/// "Result": the verdict, key figures and next step, edged by the verdict colour. The full answer folds in here,
/// or sits in its own card (`AutoRunAnswerCard`) when the pane is wide.
struct AutoRunResultBlock: View {
    let run: AutoRun
    var showsFullAnswer = true
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if run.state == .skipped {
                Text("Session open, start it manually").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                verdictLine
                figures
                nextStep
                if showsFullAnswer {
                    fullAnswer
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .leading) { run.tint.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            denials
            Spacer(minLength: 8)
            Text(meta).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
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
                Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var figures: some View {
        if !run.figures.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                label("Key figures")
                ForEach(Array(run.figures.enumerated()), id: \.offset) { _, figure in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Image(systemName: "circle.fill")).font(.system(size: 5)).baselineOffset(2.5).foregroundStyle(run.tint)
                        Text(Self.inline(figure)).font(.system(size: 13)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The step the owner takes next, set apart: it is what they act on after reading the verdict.
    @ViewBuilder
    private var nextStep: some View {
        if let step = run.nextStep, !step.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    label("Next step")
                    Text(Self.inline(step)).font(.system(size: 13)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var denials: some View {
        if let count = run.denials, count > 0 {
            Label("\(count) actions denied", systemImage: "hand.raised")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.verdictWatch)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.verdictWatch.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var fullAnswer: some View {
        if let output = run.trimmedOutput {
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.bottom, 6)
                // A plain DisclosureGroup only reacts on its chevron on macOS: the whole row toggles here.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Full answer (\(run.outputLineCount) lines)").font(.system(size: 12))
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

    /// `code` spans in monospace, as Claude writes paths and values; anything else stays plain text.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The whole answer, unfolded in the side column of a wide pane.
struct AutoRunAnswerCard: View {
    let run: AutoRun

    var body: some View {
        if let output = run.trimmedOutput {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude's answer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                MarkdownView(markdown: output)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

extension AutoRun {
    /// The answer, nil when Claude printed nothing.
    var trimmedOutput: String? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return output
    }

    var outputLineCount: Int {
        output?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
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
    /// 2 in one column, where a single run is already the result block; 1 in the wide side column.
    var minimum = 2
    @State private var runs: [AutoRun] = []

    var body: some View {
        Group {
            if runs.count >= minimum {
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
