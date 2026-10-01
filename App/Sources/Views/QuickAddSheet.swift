import SwiftUI
import TicklerCore

/// New reminder (⌘N), as designed: big title, a "when" field that shows what it understood, quick picks,
/// and notes whose links show up as they are typed.
struct QuickAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var when = ""
    @State private var picked: SnoozePreset?
    @State private var notes = ""
    @FocusState private var focus: Field?

    private enum Field { case title, when, notes }

    private static let quickPicks: [SnoozePreset] = [.oneHour, .thisAfternoon, .tomorrowMorning, .nextMonday]

    var body: some View {
        let due = dueDate
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 18) {
                whenSection(due)
                notesSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            footer(due)
        }
        .frame(width: 560)
        .background(Theme.listBackground)
        .onAppear { focus = .title }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                Text("New Reminder").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Esc to close").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            TextField("Title", text: $title, prompt: Text("What needs doing?").foregroundStyle(.tertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1 ... 3)
                .focused($focus, equals: .title)
                .onSubmit { focus = .when }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private func whenSection(_ due: Date?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("When")
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(due == nil ? Color.secondary : Theme.accent)
                TextField("When", text: $when, prompt: Text("tomorrow 9:30, lundi 10h, in 2h").foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .when)
                    .onChange(of: when) { _, typed in
                        if !typed.isEmpty {
                            picked = nil
                        }
                    }
                    .onSubmit { focus = .notes }
                if let due {
                    Text(Format.dueLabel(due, now: model.now))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    Text(Format.relative(due, now: model.now)).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if !when.isEmpty {
                    Text("Not understood yet").font(.system(size: 12)).foregroundStyle(Theme.overdue)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(due == nil ? Color.primary.opacity(0.12) : Theme.accent.opacity(0.7)))
            FlowLayout(spacing: 6) {
                ForEach(Self.quickPicks.filter { $0.date(from: model.now) != nil }, id: \.self) { preset in
                    let selected = picked == preset
                    Button {
                        when = ""
                        picked = preset
                    } label: {
                        Text(preset.chipTitle)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .foregroundStyle(selected ? Theme.accent : Color.primary.opacity(0.85))
                            .background(selected ? Theme.accent.opacity(0.16) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.18)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Notes")
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Context, command, links (MR, ticket, Slack thread)…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .notes)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(height: 120)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(focus == .notes ? 0.25 : 0.12)))
            let links = LinkExtractor.links(reminderId: "", notes: notes, explicit: [])
            if !links.isEmpty {
                HStack(spacing: 6) {
                    Text("Detected:").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(links, id: \.position) { link in
                        HStack(spacing: 5) {
                            LinkBadge(kind: link.kind)
                            Text(link.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func footer(_ due: Date?) -> some View {
        HStack(spacing: 8) {
            Text("⌘↩ to add").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Add") { add(due) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(due == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Helpers

    /// A quick pick wins until the user types a date again.
    private var dueDate: Date? {
        if let picked {
            return picked.date(from: model.now)
        }
        return DateParser(preferred: Format.locale.language.languageCode?.identifier ?? "en").parse(when)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func add(_ due: Date?) {
        guard let due else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.add(title: trimmed, notes: notes, dueAt: due)
        dismiss()
    }
}

extension SnoozePreset {
    /// Quick picks in the new reminder sheet: they name the time, unlike snooze ("1 hour").
    var chipTitle: LocalizedStringKey {
        switch self {
        case .fifteenMinutes: "In 15 min"
        case .oneHour: "In 1 hour"
        case .thisAfternoon: "This afternoon"
        case .tomorrowMorning: "Tomorrow 9:30"
        case .nextMonday: "Monday 9:30"
        }
    }
}
