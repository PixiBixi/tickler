import SwiftUI
import TicklerCore

/// The scheduling mode, with one line saying what it does. Shared by Settings and onboarding.
struct SchedulingModeRow: View {
    @Binding var schedule: WorkSchedule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Scheduling", selection: $schedule.mode) {
                Text("Automatic").tag(SchedulingMode.auto)
                Text("Place only").tag(SchedulingMode.placeOnly)
                Text("Off").tag(SchedulingMode.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: LocalizedStringKey {
        switch schedule.mode {
        case .auto: "Places new reminders and moves them around meetings and freed slots."
        case .placeOnly: "Places new reminders in a free slot, then never moves them."
        case .off: "Reminders keep the time they get. Nothing is moved."
        }
    }
}

/// One toggle button per weekday, Monday first; at least one stays on.
struct WorkingDaysRow: View {
    @Binding var schedule: WorkSchedule

    private static let weekOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.weekOrder, id: \.self) { day in
                dayToggle(day)
            }
        }
    }

    private func dayToggle(_ day: Int) -> some View {
        let isOn = schedule.workingDays.contains(day)
        return Toggle(Self.symbols().shortStandaloneWeekdaySymbols[day - 1], isOn: Binding(
            get: { isOn },
            set: { enabled in
                if enabled {
                    schedule.workingDays.insert(day)
                } else if schedule.workingDays.count > 1 {
                    schedule.workingDays.remove(day)
                }
            }
        ))
        .toggleStyle(.button)
        .accessibilityLabel(Text(Self.symbols().standaloneWeekdaySymbols[day - 1]))
    }

    private static func symbols() -> Calendar {
        var calendar = Calendar.current
        calendar.locale = Format.locale
        return calendar
    }
}

struct WorkingHoursRow: View {
    @Binding var schedule: WorkSchedule

    var body: some View {
        LabeledContent("Hours") {
            TimeRangeFields(
                from: Binding(get: { schedule.start.minutes }, set: { schedule.start = TimeOfDay(minutes: $0) }),
                to: Binding(get: { schedule.end.minutes }, set: { schedule.end = TimeOfDay(minutes: $0) }),
                minimumGap: 5
            )
        }
    }
}

/// One row: the checklist opens in a popover, grouped by account, so a long calendar list does not stretch the window.
struct BusyCalendarsRow: View {
    @Environment(AppModel.self) private var model
    @Binding var schedule: WorkSchedule
    var noAccessHint: LocalizedStringKey = "Allow access in the Calendar tab"
    @State private var showCalendars = false

    var body: some View {
        LabeledContent("Meetings that block time") {
            if model.calendarSync.hasAccess {
                Button(summary) { showCalendars = true }
                    .popover(isPresented: $showCalendars, arrowEdge: .trailing) { list }
            } else {
                Text(noAccessHint).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let count = schedule.busyCalendarIds.count
        return count == 0 ? String(localized: "None") : String(localized: "\(count) calendars")
    }

    private var list: some View {
        let groups = Dictionary(grouping: model.calendarSync.busyCandidates, by: { $0.source.title })
        let listed = Set(model.calendarSync.busyCandidates.map(\.calendarIdentifier))
        let missing = schedule.busyCalendarIds.filter { !listed.contains($0) }
        return Form {
            ForEach(groups.keys.sorted(), id: \.self) { source in
                Section(source) {
                    ForEach(groups[source] ?? [], id: \.calendarIdentifier) { calendar in
                        Toggle(calendar.title, isOn: binding(calendar.calendarIdentifier))
                    }
                }
            }
            if !missing.isEmpty {
                Section {
                    ForEach(missing, id: \.self) { id in
                        Toggle("Unavailable calendar", isOn: binding(id))
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Only start and end times are read.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
        .frame(width: 320, height: 420)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { schedule.busyCalendarIds.contains(id) }, set: { toggle(id, enabled: $0) })
    }

    private func toggle(_ id: String, enabled: Bool) {
        if enabled {
            if !schedule.busyCalendarIds.contains(id) {
                schedule.busyCalendarIds.append(id)
            }
        } else {
            schedule.busyCalendarIds.removeAll { $0 == id }
        }
    }
}

/// Loads the stored schedule into `schedule` and saves every edit at once, fitted to the working hours.
struct SavesSchedule: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var schedule: WorkSchedule

    func body(content: Content) -> some View {
        content
            .onAppear {
                schedule = model.currentSchedule()
                model.calendarSync.loadCalendars()
            }
            .onChange(of: schedule) { _, value in
                let fitted = Self.fitted(value)
                if fitted == value {
                    model.saveSchedule(value)
                } else {
                    schedule = fitted
                }
            }
    }

    /// Shrinking the working hours pulls the lunch window and the default duration inside them.
    private static func fitted(_ value: WorkSchedule) -> WorkSchedule {
        var result = value
        if var lunch = result.lunch {
            lunch.from = TimeOfDay(minutes: max(lunch.from.minutes, result.start.minutes))
            lunch.to = TimeOfDay(minutes: min(lunch.to.minutes, result.end.minutes))
            let room = lunch.to.minutes - lunch.from.minutes
            lunch.minutes = min(lunch.minutes, room)
            result.lunch = room >= 5 ? lunch : nil
        }
        result.defaultDurationMinutes = min(result.defaultDurationMinutes, max(5, result.workingMinutes))
        return result
    }
}

extension View {
    func savesSchedule(_ schedule: Binding<WorkSchedule>) -> some View {
        modifier(SavesSchedule(schedule: schedule))
    }
}
