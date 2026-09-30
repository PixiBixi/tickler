import SwiftUI
import TicklerCore

struct ReminderListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            DayStrip()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if model.visibleGroups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.seal", description: Text(emptyDetail))
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleGroups) { group in
                        Section {
                            ForEach(group.reminders) { reminder in
                                ReminderRow(reminder: reminder).tag(reminder.id)
                            }
                        } header: {
                            HStack {
                                Text(Format.title(for: group.bucket))
                                Spacer()
                                Text("\(group.reminders.count)").monospacedDigit()
                            }
                            .foregroundStyle(group.bucket == .overdue ? Theme.overdue : .secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        Button("Mark Done") { model.markDone(id) }
                        Menu("Snooze") {
                            ForEach(SnoozePreset.available(now: model.now), id: \.self) { preset in
                                Button(preset.title) { model.snooze(id, preset: preset) }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { model.delete(id) }
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Button { model.showQuickAdd = true } label: { Label("New Reminder", systemImage: "plus") }
                    .help("New Reminder (⌘N)")
            }
        }
    }

    private var title: String {
        switch model.filter {
        case .today: String(localized: "Today")
        case .week: String(localized: "Next 7 Days")
        case .overdue: String(localized: "Overdue")
        case .all: String(localized: "All Reminders")
        case .done: String(localized: "Done")
        case let .day(day): day.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(Format.locale))
        case let .project(name): name
        }
    }

    private var emptyTitle: LocalizedStringKey {
        model.search.isEmpty ? "Nothing here" : "No match"
    }

    private var emptyDetail: LocalizedStringKey {
        model.search.isEmpty ? "Enjoy it." : "Try other words."
    }
}

/// Seven days from today; a click filters the list on that day.
struct DayStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: model.now)
        HStack(spacing: 4) {
            ForEach(0 ..< 7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start)!
                let count = model.reminders(for: .day(day)).count + (offset == 0 ? model.overdueCount - overdueToday(day) : 0)
                let selected = model.filter == .day(day)
                Button {
                    model.filter = selected ? .today : .day(day)
                } label: {
                    VStack(spacing: 2) {
                        Text(Format.weekdayShort(day)).font(.system(size: 10)).opacity(0.8)
                        Text(Format.dayNumber(day)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        Text(count == 0 ? " " : "\(count)").font(.system(size: 10)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selected ? Theme.onAccent : (count == 0 ? Color.secondary.opacity(0.6) : Color.primary))
                    .background(selected ? Theme.accent : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(day.formatted(date: .complete, time: .omitted)), \(count) reminders"))
            }
        }
    }

    /// Overdue reminders from today are already counted on today's tile.
    private func overdueToday(_ today: Date) -> Int {
        model.open.count { $0.dueAt < model.now && Calendar.current.isDate($0.dueAt, inSameDayAs: today) }
    }
}

struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        let bucket = reminder.status == .done ? DueBucket.later : DueBucket.of(reminder.dueAt, now: model.now)
        let soon = reminder.isSoon(now: model.now)
        HStack(spacing: 10) {
            Circle().fill(Theme.dot(for: bucket, soon: soon)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.system(size: 13)).lineLimit(1)
                    .strikethrough(reminder.status == .done, color: .secondary)
                HStack(spacing: 4) {
                    Text(Format.dueLabel(reminder.dueAt, now: model.now))
                        .foregroundStyle(bucket == .overdue ? Theme.overdue : (soon ? Theme.accent : .secondary))
                    if let project = reminder.project {
                        Text("·").foregroundStyle(.tertiary)
                        Text(project).foregroundStyle(.secondary)
                    }
                    if reminder.rescheduleCount > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "arrow.uturn.forward").foregroundStyle(.secondary)
                            .help(Text("Rescheduled \(reminder.rescheduleCount) times"))
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            let count = model.links(of: reminder).count
            if count > 0 {
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    + Text(Image(systemName: "link")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
