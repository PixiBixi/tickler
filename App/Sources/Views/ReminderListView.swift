import SwiftUI
import TicklerCore

struct ReminderListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            DayStrip()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            Divider()
            if model.visibleGroups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.seal", description: Text(emptyDetail))
                    .frame(maxHeight: .infinity)
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
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Title, search and add sit in the column itself, level with the traffic lights.
    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(width: 160, height: 28)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            Button { model.showQuickAdd = true } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .help("New Reminder (⌘N)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
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

/// Seven days from today, moved a week at a time; a click filters the list on a day, a second click goes back to Today.
struct DayStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: model.stripWeek * 7, to: calendar.startOfDay(for: model.now))!
        HStack(spacing: 4) {
            weekButton("chevron.left", step: -1, help: "Previous week")
            ForEach(0 ..< 7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start)!
                let items = model.reminders(for: .day(day))
                let isToday = calendar.isDateInToday(day)
                DayTile(
                    day: day,
                    isToday: isToday,
                    total: items.count { $0.status == .open } + (isToday ? model.overdueCount - overdueToday(day) : 0),
                    finished: items.count { $0.status == .done },
                    hasOverdue: (isToday && model.overdueCount > 0) || items.contains { $0.status == .open && $0.dueAt < model.now },
                    isWeekend: calendar.isDateInWeekend(day),
                    isSelected: model.filter == .day(day)
                ) {
                    model.filter = model.filter == .day(day) ? .today : .day(day)
                }
            }
            weekButton("chevron.right", step: 1, help: "Next week")
        }
    }

    private func weekButton(_ symbol: String, step: Int, help: LocalizedStringKey) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { model.stripWeek += step } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 64)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// Overdue reminders from today are already counted on today's tile.
    private func overdueToday(_ today: Date) -> Int {
        model.open.count { $0.dueAt < model.now && Calendar.current.isDate($0.dueAt, inSameDayAs: today) }
    }
}

private struct DayTile: View {
    let day: Date
    let isToday: Bool
    let total: Int
    let finished: Int
    let hasOverdue: Bool
    let isWeekend: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(isToday ? String(localized: "Today") : Format.weekdayShort(day))
                    .font(.system(size: 10, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? Theme.accent : .secondary)
                    .lineLimit(1)
                Text(Format.dayNumber(day))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Theme.accent : (isWeekend ? Color.secondary : Color.primary))
                    .frame(height: 28)
                dots
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text("\(day.formatted(date: .complete, time: .omitted)), \(total) reminders"))
    }

    /// Up to three dots, then a total: the load of the day at a glance. Red when something is overdue.
    private var dots: some View {
        HStack(spacing: 3) {
            if total == 0 {
                Color.clear.frame(width: 5, height: 5)
            } else if total <= 3 {
                ForEach(0 ..< total, id: \.self) { index in
                    Circle().fill(index == 0 && hasOverdue ? Theme.overdue : Theme.accent.opacity(0.85)).frame(width: 5, height: 5)
                }
            } else {
                Circle().fill(hasOverdue ? Theme.overdue : Theme.accent.opacity(0.85)).frame(width: 5, height: 5)
                Text(verbatim: "\(total)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(height: 9)
    }

    private var background: Color {
        if isToday {
            return Theme.accent.opacity(isSelected || hovering ? 0.3 : 0.22)
        }
        if isSelected {
            return Theme.accent.opacity(0.12)
        }
        return Color.primary.opacity(hovering ? 0.08 : (isWeekend ? 0.025 : 0.045))
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
