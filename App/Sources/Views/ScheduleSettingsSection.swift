import SwiftUI
import TicklerCore

/// Working time the planner places flexible reminders in. Every edit is saved at once.
struct ScheduleSettings: View {
    @State private var schedule = WorkSchedule.standard

    var body: some View {
        SettingsTab {
            Section("Scheduling") {
                SchedulingModeRow(schedule: $schedule)
            }
            Section("Working days") {
                WorkingDaysRow(schedule: $schedule)
            }
            Section("Working hours") {
                WorkingHoursRow(schedule: $schedule)
                DurationPicker(
                    title: "Default duration",
                    minutes: $schedule.defaultDurationMinutes,
                    limit: max(5, schedule.workingMinutes)
                )
            }
            lunchSection
            Section {
                BusyCalendarsRow(schedule: $schedule)
            }
        }
        .savesSchedule($schedule)
    }

    // MARK: Lunch

    private var lunchSection: some View {
        Section {
            Toggle("Keep a lunch break free", isOn: Binding(
                get: { schedule.lunch != nil },
                set: { schedule.lunch = $0 ? Self.defaultLunch(in: schedule) : nil }
            ))
            if let lunch = schedule.lunch {
                DurationPicker(title: "Break length", minutes: lunchMinutes, limit: max(5, lunch.to.minutes - lunch.from.minutes))
                LabeledContent("Somewhere between") {
                    TimeRangeFields(from: lunchFrom, to: lunchTo, minimumGap: lunch.minutes)
                }
            }
        } header: {
            Text("Lunch")
        }
    }

    /// 45 minutes inside 12:00-14:00, clamped to the working hours so it never falls outside the day.
    private static func defaultLunch(in schedule: WorkSchedule) -> Lunch {
        let from = min(max(12 * 60, schedule.start.minutes), schedule.end.minutes - 5)
        let to = min(max(14 * 60, from + 5), schedule.end.minutes)
        return Lunch(minutes: min(45, to - from), from: TimeOfDay(minutes: from), to: TimeOfDay(minutes: to))
    }

    private var lunchMinutes: Binding<Int> {
        Binding(get: { schedule.lunch?.minutes ?? 45 }, set: { schedule.lunch?.minutes = $0 })
    }

    private var lunchFrom: Binding<Int> {
        Binding(get: { schedule.lunch?.from.minutes ?? 0 }, set: { schedule.lunch?.from = TimeOfDay(minutes: $0) })
    }

    private var lunchTo: Binding<Int> {
        Binding(get: { schedule.lunch?.to.minutes ?? 0 }, set: { schedule.lunch?.to = TimeOfDay(minutes: $0) })
    }
}

/// Two typable times of day, kept in order with at least `minimumGap` minutes between them, snapped to the 5 min grid.
struct TimeRangeFields: View {
    @Binding var from: Int
    @Binding var to: Int
    let minimumGap: Int

    var body: some View {
        HStack(spacing: 6) {
            TimeField(minutes: $from, range: 0 ... max(0, to - minimumGap))
            Text(verbatim: "-").foregroundStyle(.secondary)
            TimeField(minutes: $to, range: min(from + minimumGap, 24 * 60 - 5) ... 24 * 60 - 5)
        }
    }
}

private struct TimeField: View {
    @Binding var minutes: Int
    let range: ClosedRange<Int>

    var body: some View {
        DatePicker(
            "",
            selection: date,
            in: Self.date(range.lowerBound) ... Self.date(range.upperBound),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.field)
        .monospacedDigit()
    }

    private var date: Binding<Date> {
        Binding(get: { Self.date(minutes) }, set: { value in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            let raw = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            minutes = min(max((raw + 2) / 5 * 5, range.lowerBound), range.upperBound)
        })
    }

    /// A fixed reference day: only the hour and minute are read back.
    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(
            byAdding: .minute,
            value: minutes,
            to: Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        ) ?? Date()
    }
}

/// Common lengths in a menu; a value set from the CLI that is not one of them stays listed.
struct DurationPicker: View {
    let title: LocalizedStringKey
    @Binding var minutes: Int
    let limit: Int

    static let presets = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        Picker(title, selection: $minutes) {
            ForEach(choices, id: \.self) { value in
                Text(verbatim: Self.label(value)).tag(value)
            }
        }
    }

    private var choices: [Int] {
        Self.choices(limit: limit, including: minutes)
    }

    /// The presets that fit, plus the current value when it is none of them.
    static func choices(limit: Int, including minutes: Int) -> [Int] {
        Set(presets.filter { $0 <= limit } + [minutes]).sorted()
    }

    /// "45 min", "2 h", "1 h 30": the short form read in both languages.
    static func label(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 {
            return "\(rest) min"
        }
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }
}
