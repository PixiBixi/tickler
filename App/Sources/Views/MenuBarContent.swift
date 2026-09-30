import SwiftUI
import TicklerCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = model.todayCount
        HStack(spacing: 3) {
            Image(model.overdueCount > 0 ? "MenuBarIconAlert" : "MenuBarIcon")
            if count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
        .onAppear {
            model.openMainWindow = {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// The popover under the menu bar icon: the next reminder with its actions, then the day at a glance.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @State private var showLater = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let next = model.nextReminder {
                NextCard(reminder: next)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.visibleGroupsForPopover) { group in
                        section(group)
                    }
                    if model.open.isEmpty {
                        Text("Nothing planned. Claude will add reminders here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 420)
            Divider()
            footer
        }
        .frame(width: 380)
        .overlay(alignment: .bottom) { ToastOverlay(toast: model.toast) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reminders").font(.system(size: 15, weight: .semibold))
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showMainWindow(); model.showQuickAdd = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New Reminder")
            Button { model.showMainWindow() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help("Open Window")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var summary: String {
        let today = model.todayCount
        let overdue = model.overdueCount
        if today == 0 {
            return String(localized: "Nothing due today")
        }
        if overdue == 0 {
            return String(localized: "\(today) today")
        }
        return String(localized: "\(today) today, \(overdue) overdue")
    }

    @ViewBuilder
    private func section(_ group: ReminderGroup) -> some View {
        if group.bucket == .later, !showLater {
            Button { showLater = true } label: {
                HStack {
                    Text("Later")
                    Spacer()
                    Text("\(group.reminders.count)").monospacedDigit()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        } else {
            Text(Format.title(for: group.bucket))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(group.bucket == .overdue ? Theme.overdue : .secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(group.reminders) { reminder in
                CompactRow(reminder: reminder)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Window") { model.showMainWindow() }
                .buttonStyle(.borderless)
                .keyboardShortcut("o")
            Spacer()
            CalendarStatusLabel()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension AppModel {
    /// The popover always shows overdue, today, tomorrow and later, whatever the window's filter is.
    var visibleGroupsForPopover: [ReminderGroup] {
        let grouped = Dictionary(grouping: open.filter { $0.id != nextReminder?.id }) { DueBucket.of($0.dueAt, now: now) }
        return DueBucket.allCases.compactMap { bucket in grouped[bucket].map { ReminderGroup(bucket: bucket, reminders: $0) } }
    }
}

private struct NextCard: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Next, \(Format.relative(reminder.dueAt, now: model.now))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(Format.time(reminder.dueAt)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                let detail = [reminder.project, linkSummary].compactMap(\.self).joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if reminder.sessionId != nil {
                    Button { model.resume(reminder) } label: {
                        Label("Resume", systemImage: "terminal").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                SnoozeMenu(reminderId: reminder.id)
                Button("Done") { model.markDone(reminder.id) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(reminder.id) }
    }

    private var linkSummary: String? {
        let count = model.links(of: reminder).count
        return count == 0 ? nil : String(localized: "\(count) links")
    }
}

private struct CompactRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var hovering = false

    var body: some View {
        let bucket = DueBucket.of(reminder.dueAt, now: model.now)
        HStack(spacing: 10) {
            Circle().fill(Theme.dot(for: bucket, soon: reminder.isSoon(now: model.now))).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.system(size: 13)).lineLimit(1)
                Text(subtitle(bucket))
                    .font(.system(size: 11))
                    .foregroundStyle(bucket == .overdue ? Theme.overdue : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 2) {
                    if reminder.sessionId != nil {
                        iconButton("terminal", help: "Resume Session") { model.resume(reminder) }
                    }
                    iconButton("clock", help: "Snooze 1 hour") { model.snooze(reminder.id, preset: .oneHour) }
                    iconButton("checkmark", help: "Mark Done") { model.markDone(reminder.id) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(reminder.id) }
        .padding(.horizontal, 6)
    }

    private func subtitle(_ bucket: DueBucket) -> String {
        let when = bucket == .overdue || bucket == .today ? Format.time(reminder.dueAt) : Format.dueLabel(reminder.dueAt, now: model.now)
        let relative = bucket == .overdue ? Format.relative(reminder.dueAt, now: model.now) : reminder.project
        return [when, relative].compactMap(\.self).joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .help(help)
    }
}

struct SnoozeMenu: View {
    @Environment(AppModel.self) private var model
    let reminderId: String

    var body: some View {
        Menu {
            ForEach(SnoozePreset.available(now: model.now), id: \.self) { preset in
                Button {
                    model.snooze(reminderId, preset: preset)
                } label: {
                    Text(preset.title) + Text(verbatim: "  ") +
                        Text(preset.date(from: model.now).map { Format.dueLabel($0, now: model.now) } ?? "")
                }
            }
        } label: {
            Label("Snooze", systemImage: "clock")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
    }
}

extension SnoozePreset {
    var title: LocalizedStringKey {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .thisAfternoon: "This afternoon"
        case .tomorrowMorning: "Tomorrow morning"
        case .nextMonday: "Monday"
        }
    }
}

struct CalendarStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (color, text) = describe(model.calendarSync.status)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(2)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func describe(_ status: CalendarService.Status) -> (Color, String) {
        switch status {
        case .disabled: (.secondary, String(localized: "Calendar sync off"))
        case .needsAccess: (.orange, String(localized: "Calendar access needed"))
        case .synced: (.green, String(localized: "Calendar up to date"))
        case let .failed(message): (Theme.overdue, message)
        }
    }
}
