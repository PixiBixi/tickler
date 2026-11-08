import SwiftUI
import TicklerCore

/// Done and Snooze (or Reopen for a done reminder), Delete in the overflow menu. Sits at the top right of the header.
struct DetailActions: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    let pickDate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if reminder.status == .open {
                Button { model.markDone(reminder.id) } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("⌘↩")
                SnoozeMenu(reminderId: reminder.id, onPickDate: pickDate)
            } else {
                Button { reopen() } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Menu {
                Button("Delete", role: .destructive) { model.delete(reminder.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More actions"))
        }
    }

    private func reopen() {
        let date = reminder.dueAt > Date() ? reminder.dueAt : (SnoozePreset.oneHour.date(from: Date()) ?? Date())
        model.reschedule(reminder.id, to: date)
    }
}

/// The calendar copy, or who created the reminder when it is not in the calendar.
struct DetailCalendarLine: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        Label(text, systemImage: "calendar")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var text: String {
        let start = Format.time(reminder.dueAt)
        let end = Format.time(reminder.dueAt.addingTimeInterval(Double(reminder.durationMinutes) * 60))
        if case .synced = model.calendarSync.status, reminder.status == .open {
            return String(localized: "Also in your calendar, \(start) to \(end)")
        }
        let created = Format.dueLabel(reminder.createdAt, now: model.now)
        if reminder.source == .claude {
            return String(localized: "Created \(created) by Claude")
        }
        return String(localized: "Created \(created) by you")
    }
}

/// Links that neither carry a live status nor appear in the notes: the notes already link the others inline.
struct DetailExtraLinks: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    let notes: String

    var body: some View {
        let tracked = Set(model.liveStatus.supported(model.links(of: reminder)).map(\.url))
        let links = model.links(of: reminder).filter { !tracked.contains($0.url) && !notes.contains($0.url) }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Links").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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
}
