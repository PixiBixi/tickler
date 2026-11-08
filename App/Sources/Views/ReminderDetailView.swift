import SwiftUI
import TicklerCore

/// One centered column: project, title, setting chips, the session, live status, notes. Done and Delete stay under the scroll area.
struct ReminderDetailView: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    @State private var title = ""
    @State private var notes = ""
    /// What the fields started from: only a field the user changed is written back, so a CLI edit meanwhile survives.
    @State private var loadedTitle = ""
    @State private var loadedNotes = ""
    @State private var dateText = ""
    @State private var editingDate = false
    @State private var editingNotes = false
    @State private var dismissedSuggestion = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(alignment: .leading, spacing: 8) {
                        DetailChipRow(reminder: reminder, editingDate: $editingDate, dateText: dateText)
                        DetailCalendarLine(reminder: reminder)
                    }
                    doneSuggestion
                    TriggerRow(reminder: reminder)
                    if DetailSessionCard.isShown(reminder, model: model) {
                        DetailSessionCard(reminder: reminder)
                    }
                    if let run = model.finishedRun(for: reminder) {
                        AutoRunResultBlock(run: run)
                    }
                    LiveStatusSection(reminder: reminder)
                    DetailExtraLinks(reminder: reminder, notes: notes)
                    AutoRunRunsList(reminder: reminder)
                    NotesView(text: $notes, isEditing: $editingNotes, focused: $notesFocused, onCommit: commitNotes)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            title = reminder.title
            notes = reminder.notes
            loadedTitle = reminder.title
            loadedNotes = reminder.notes
            if model.focusDateField {
                dateText = model.prefilledDateText ?? ""
                editingDate = true
                model.focusDateField = false
                model.prefilledDateText = nil
            }
        }
        .onChange(of: notesFocused) { _, focused in
            if !focused {
                editingNotes = false
                commitNotes()
            }
        }
        .onDisappear { commitNotes() }
        .onChange(of: reminder.title) { _, newValue in
            if title == loadedTitle {
                title = newValue
            }
            loadedTitle = newValue
        }
        .onChange(of: reminder.notes) { _, newValue in
            if notes == loadedNotes {
                notes = newValue
            }
            loadedNotes = newValue
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if let cwd = reminder.cwd, !cwd.isEmpty {
                    Text(verbatim: Self.projectName(cwd))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(cwd)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                DetailActions(reminder: reminder, pickDate: startRescheduling)
            }
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .onSubmit(commitTitle)
        }
    }

    /// The folder's last component, or "~" for the home folder itself.
    private static func projectName(_ cwd: String) -> String {
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        return url.path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path ? "~" : url.lastPathComponent
    }

    // MARK: Done suggestion

    /// Everything linked is merged or done: the reminder has most likely served its purpose.
    @ViewBuilder
    private var doneSuggestion: some View {
        if reminder.status == .open, !dismissedSuggestion, let statuses = model.liveStatus.allFinished(model.links(of: reminder)) {
            let counts = LiveStatus.finishedSummary(statuses)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything linked is finished").font(.system(size: 13, weight: .semibold))
                    Text(Self.describe(counts)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not yet") { dismissedSuggestion = true }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Mark Done") { model.markDone(reminder.id) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(12)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.35)))
        }
    }

    private static func describe(_ counts: FinishedCounts) -> String {
        var parts: [String] = []
        if counts.mergeRequests > 0 {
            parts.append(String(localized: "\(counts.mergeRequests) MRs merged or closed"))
        }
        if counts.pullRequests > 0 {
            parts.append(String(localized: "\(counts.pullRequests) PRs merged or closed"))
        }
        if counts.tickets > 0 {
            parts.append(String(localized: "\(counts.tickets) tickets done"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Editing

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != loadedTitle, !trimmed.isEmpty, trimmed != reminder.title else { return }
        loadedTitle = title
        model.update(reminder.id, title: trimmed)
    }

    private func commitNotes() {
        commitTitle()
        guard notes != loadedNotes, notes != reminder.notes else { return }
        loadedNotes = notes
        model.update(reminder.id, notes: notes)
    }

    private func startRescheduling() {
        dateText = ""
        editingDate = true
    }
}
