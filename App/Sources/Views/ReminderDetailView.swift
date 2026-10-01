import SwiftUI
import TicklerCore

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
    @State private var paneSize = CGSize(width: 800, height: 700)
    @State private var editingNotes = false
    @State private var sessionHover = false
    @FocusState private var dateFocused: Bool
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                // Wide windows (full screen): the context rail moves to the right instead of piling up below.
                if paneSize.width >= Self.twoColumnWidth {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            actions
                            notesSection(minHeight: max(260, paneSize.height - 280))
                        }
                        .frame(maxWidth: 820, alignment: .leading)
                        VStack(alignment: .leading, spacing: 18) {
                            LiveStatusSection(reminder: reminder)
                            linksSection
                            sessionSection
                        }
                        .frame(width: 400)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        actions
                        LiveStatusSection(reminder: reminder)
                        notesSection(minHeight: 120)
                        linksSection
                        sessionSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
            // Fill the pane: sized to its content, the scroller sat mid-pane and the width read here stayed narrow.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { paneSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in paneSize = size }
            })
            Divider()
            footer
        }
        .onAppear {
            title = reminder.title
            notes = reminder.notes
            loadedTitle = reminder.title
            loadedNotes = reminder.notes
            if model.focusDateField {
                dateText = model.prefilledDateText ?? ""
                editingDate = true
                dateFocused = true
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
        VStack(alignment: .leading, spacing: 10) {
            dueChip
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .bold))
                .onSubmit(commitTitle)
            if let cwd = reminder.cwd {
                Text(abbreviate(cwd))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var dueChip: some View {
        if editingDate {
            DateEntryField(text: $dateText, focused: $dateFocused) { date in
                editingDate = false
                if let date {
                    model.reschedule(reminder.id, to: date)
                }
            }
        } else {
            let bucket = DueBucket.of(reminder.dueAt, now: model.now)
            let soon = reminder.isSoon(now: model.now)
            let color = reminder.status == .done ? Color
                .secondary : (bucket == .overdue ? Theme.overdue : (soon ? Theme.accent : Color.primary))
            Button {
                dateText = ""
                editingDate = true
                dateFocused = true
            } label: {
                HStack(spacing: 6) {
                    Text(Format.dueLabel(reminder.dueAt, now: model.now))
                    if reminder.status == .open {
                        Text("·")
                        Text(Format.relative(reminder.dueAt, now: model.now))
                    }
                    if reminder.rescheduleCount > 0 {
                        Text("·")
                        Text("rescheduled \(reminder.rescheduleCount)×")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Change the date")
        }
    }

    // MARK: Actions

    private var actions: some View {
        let targets = LinkTargets(links: model.links(of: reminder))
        return HStack(spacing: 8) {
            if reminder.sessionId != nil {
                Button { model.resume(reminder) } label: {
                    Label("Resume Session", systemImage: "terminal")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("⌘R")
            }
            if reminder.status == .open {
                SnoozeMenu(reminderId: reminder.id)
                Button { model.markDone(reminder.id) } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("⌘↩")
            } else {
                Button { reopen() } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let ticket = targets.ticket {
                Button("Open \(ticket.label)") { model.open(ticket) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let slack = targets.slack {
                Button("Open Slack Thread") { model.open(slack) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: Sections

    static let twoColumnWidth: CGFloat = 1000

    private func notesSection(minHeight: CGFloat) -> some View {
        NotesView(text: $notes, isEditing: $editingNotes, focused: $notesFocused, minHeight: minHeight, onCommit: commitNotes)
    }

    @ViewBuilder
    private var linksSection: some View {
        // MRs, tickets and PRs already have a live card above: list only the other links.
        let tracked = Set(model.liveStatus.supported(model.links(of: reminder)).map(\.url))
        let links = model.links(of: reminder).filter { !tracked.contains($0.url) }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Links")
                ForEach(links, id: \.position) { link in
                    Button { model.open(link) } label: {
                        HStack(spacing: 10) {
                            LinkBadge(kind: link.kind)
                            Text(link.label).font(.system(size: 13))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(link.url)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        if let sessionId = reminder.sessionId {
            let running = model.runningSessions.contains(sessionId)
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Claude Session")
                // The whole row resumes the session: state first, the id truncated in the middle when space runs out.
                Button { model.resume(reminder) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(running ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                        Text(running ? "Running" : "Ended")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(running ? .green : .secondary)
                            .fixedSize()
                        Text(verbatim: sessionId)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Label(running ? "Show Tab" : "Reopen", systemImage: "terminal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(sessionHover ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { sessionHover = $0 }
                .help(sessionId)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            Text(footerText)
            Spacer()
            Button("Delete", role: .destructive) { model.delete(reminder.id) }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private var footerText: String {
        let start = Format.time(reminder.dueAt)
        let end = Format.time(reminder.dueAt.addingTimeInterval(15 * 60))
        if case .synced = model.calendarSync.status, reminder.status == .open {
            return String(localized: "Also in your calendar, \(start) to \(end)")
        }
        let created = Format.dueLabel(reminder.createdAt, now: model.now)
        if reminder.source == .claude {
            return String(localized: "Created \(created) by Claude")
        }
        return String(localized: "Created \(created) by you")
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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

    private func reopen() {
        let date = reminder.dueAt > Date() ? reminder.dueAt : (SnoozePreset.oneHour.date(from: Date()) ?? Date())
        model.reschedule(reminder.id, to: date)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Free-text date input with a live preview of what was understood.
struct DateEntryField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onFinish: (Date?) -> Void

    var body: some View {
        let parsed = parse(text)
        HStack(spacing: 8) {
            TextField("tomorrow 2pm, lundi 10h, in 3h", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused(focused)
                .onSubmit { onFinish(parsed) }
                .onExitCommand { onFinish(nil) }
            if let parsed {
                Text(Format.dueLabel(parsed, now: Date())).font(.system(size: 12)).foregroundStyle(Theme.accent)
            } else if !text.isEmpty {
                Text("Not understood").font(.system(size: 12)).foregroundStyle(Theme.overdue)
            }
            Button("Cancel") { onFinish(nil) }.buttonStyle(.borderless)
        }
    }

    private func parse(_ text: String) -> Date? {
        DateParser(preferred: Format.locale.language.languageCode?.identifier ?? "en").parse(text)
    }
}
