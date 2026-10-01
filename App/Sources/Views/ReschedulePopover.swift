import SwiftUI
import TicklerCore

/// Reschedule panel: free text, quick picks, a month grid and a time, all landing on one date shown at the bottom.
struct ReschedulePopover: View {
    @Environment(AppModel.self) private var model
    let current: Date
    var initialText = ""
    let onFinish: (Date?) -> Void

    @State private var text = ""
    @State private var day: Date?
    @State private var time = ""
    @State private var month = Date()
    @FocusState private var textFocused: Bool

    private let calendar = Calendar.current
    private static let times = ["09:00", "10:00", "11:00", "14:00", "16:00", "18:00"]
    private static let picks: [SnoozePreset] = [.oneHour, .thisAfternoon, .tomorrowMorning, .nextMonday]

    var body: some View {
        let choice = chosenDate
        VStack(alignment: .leading, spacing: 14) {
            textField(parsed: parsedText)
            FlowLayout(spacing: 6) {
                ForEach(Self.picks.filter { $0.date(from: model.now) != nil }, id: \.self) { preset in
                    chip(preset.chipTitle, selected: false) { apply(preset.date(from: Date())) }
                }
            }
            Divider()
            monthGrid
            timeRow
            Divider()
            footer(choice)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            text = initialText
            let start = max(current, Date())
            month = start
            day = calendar.startOfDay(for: start)
            time = Self.format(start, "HH:mm")
            textFocused = true
        }
    }

    // MARK: Parts

    private func textField(parsed: Date?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor").font(.system(size: 12)).foregroundStyle(parsed == nil ? Color.secondary : Theme.accent)
            TextField("When", text: $text, prompt: Text("jeudi 14h, in 3h, tomorrow 9:30").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($textFocused)
                .onSubmit { finish(chosenDate) }
                .onExitCommand { onFinish(nil) }
            if !text.isEmpty, parsed == nil {
                Text("Not understood").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(parsed == nil ? Color.primary.opacity(0.12) : Theme.accent.opacity(0.7)))
    }

    private var monthGrid: some View {
        let days = gridDays
        let symbols = Self.weekdaySymbols(calendar)
        return VStack(spacing: 6) {
            HStack {
                Text(Self.format(month, "LLLL yyyy").capitalized).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }
            .font(.system(size: 11, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
                ForEach(days, id: \.self) { date in
                    dayCell(date)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isPast = date < calendar.startOfDay(for: Date())
        let isToday = calendar.isDateInToday(date)
        let isSelected = day.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let busy = model.open.contains { calendar.isDate($0.dueAt, inSameDayAs: date) }
        return Button {
            day = date
            text = ""
        } label: {
            VStack(spacing: 1) {
                Text(Self.format(date, "d"))
                    .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular))
                    .monospacedDigit()
                Circle().fill(busy && !isSelected ? Theme.accent.opacity(0.8) : .clear).frame(width: 4, height: 4)
            }
            .frame(width: 34, height: 30)
            .foregroundStyle(isSelected ? Theme.onAccent : (isPast || !inMonth ? Color.secondary.opacity(0.45) : Color.primary))
            .background(isSelected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isToday && !isSelected ? Theme.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPast)
    }

    private var timeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("HH:MM", text: $time)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 56)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .onChange(of: time) { _, _ in
                        if !text.isEmpty {
                            text = ""
                        }
                    }
            }
            FlowLayout(spacing: 6) {
                ForEach(Self.times, id: \.self) { value in
                    chip(LocalizedStringKey(value), selected: time == value) {
                        time = value
                        text = ""
                    }
                }
            }
        }
    }

    private func footer(_ choice: Date?) -> some View {
        HStack(spacing: 8) {
            if let choice {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.dueLabel(choice, now: Date())).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(Format.relative(choice, now: Date())).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Pick a day and a time").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onFinish(nil) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Reschedule") { finish(choice) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(choice.map { $0 <= Date() } ?? true)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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

    // MARK: Logic

    private var parsedText: Date? {
        DateParser(preferred: Format.locale.language.languageCode?.identifier ?? "en").parse(text)
    }

    /// Typed text wins; otherwise the picked day at the picked time.
    private var chosenDate: Date? {
        if let parsedText {
            return parsedText
        }
        guard let day, let match = time.wholeMatch(of: /(\d{1,2})[:h](\d{2})/), let hour = Int(match.1), let minute = Int(match.2),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private func apply(_ date: Date?) {
        guard let date else { return }
        text = ""
        day = calendar.startOfDay(for: date)
        month = date
        time = Self.format(date, "HH:mm")
    }

    private func finish(_ date: Date?) {
        guard let date, date > Date() else { return }
        onFinish(date)
    }

    private func shiftMonth(_ step: Int) {
        month = calendar.date(byAdding: .month, value: step, to: month) ?? month
    }

    /// Six weeks starting on the locale's first weekday, so the grid never jumps in height.
    private var gridDays: [Date] {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -offset, to: start)!
        return (0 ..< 42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    private static func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
