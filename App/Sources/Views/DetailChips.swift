import SwiftUI
import TicklerCore

enum ChipStyle {
    case tinted(Color)
    case neutral
    case dashed
}

/// The pill every setting of the detail header wears; the caller supplies the Button or Menu around it.
struct ChipLabel<Content: View>: View {
    let style: ChipStyle
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: isDashed ? [3, 3] : [])))
            .contentShape(Capsule())
    }

    private var isDashed: Bool {
        if case .dashed = style {
            return true
        }
        return false
    }

    private var foreground: Color {
        switch style {
        case let .tinted(color): color
        case .neutral: .primary
        case .dashed: .secondary
        }
    }

    private var fill: Color {
        switch style {
        case let .tinted(color): color.opacity(0.15)
        case .neutral: Color.primary.opacity(0.06)
        case .dashed: .clear
        }
    }

    private var border: Color {
        switch style {
        case let .tinted(color): color.opacity(0.3)
        case .neutral: Color.primary.opacity(0.12)
        case .dashed: Color.primary.opacity(0.28)
        }
    }
}

/// "Tomorrow 10:30 · in 17 h": opens the reschedule popover. The planner's move and a meeting conflict are marked on it.
struct WhenChip: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @Binding var editing: Bool
    let dateText: String
    /// The move shown, kept after it is marked seen so the mark stays while the pane is open.
    @State private var shownMove: ScheduleMove?

    var body: some View {
        let open = reminder.status == .open
        let bucket = DueBucket.of(reminder.dueAt, now: model.now)
        let tint: ChipStyle = open ? .tinted(bucket == .overdue ? Theme.overdue : Theme.accent) : .neutral
        Button { editing = true } label: {
            ChipLabel(style: tint) {
                HStack(spacing: 6) {
                    marks(open: open)
                    Text(verbatim: label(open: open))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .help("Change the date")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            ReschedulePopover(current: reminder.dueAt, initialText: dateText) { date in
                editing = false
                if let date {
                    model.reschedule(reminder.id, to: date)
                }
            }
            .environment(model)
        }
        .onAppear(perform: refreshMove)
        .onChange(of: reminder.id) { _, _ in
            shownMove = nil
            refreshMove()
        }
        .onChange(of: model.unseenMoves[reminder.id]?.id) { _, _ in refreshMove() }
    }

    private func label(open: Bool) -> String {
        let due = Format.dueLabel(reminder.dueAt, now: model.now)
        return open ? "\(due) · \(Format.relative(reminder.dueAt, now: model.now))" : due
    }

    @ViewBuilder
    private func marks(open: Bool) -> some View {
        if open, let move = shownMove {
            let text = MoveText.moved(move)
            Image(systemName: "arrow.right.circle").help(text).accessibilityLabel(text)
        }
        if open, model.conflictedIds.contains(reminder.id) {
            let text = String(localized: "Conflicts with a meeting")
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.overdue).help(text).accessibilityLabel(text)
        }
    }

    private func refreshMove() {
        guard let move = model.unseenMoves[reminder.id] else { return }
        shownMove = move
        model.markMovesSeen(reminder.id)
    }
}

/// "15 min": a menu of the lengths Settings offers, plus the current one when it is none of them.
struct DurationChip: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        let limit = max(5, model.currentSchedule().workingMinutes)
        Menu {
            ForEach(DurationPicker.choices(limit: limit, including: reminder.durationMinutes), id: \.self) { minutes in
                Button { model.setDuration(reminder.id, minutes: minutes) } label: {
                    if minutes == reminder.durationMinutes {
                        Label(DurationPicker.label(minutes), systemImage: "checkmark")
                    } else {
                        Text(verbatim: DurationPicker.label(minutes))
                    }
                }
            }
        } label: {
            ChipLabel(style: .neutral) { Text(verbatim: DurationPicker.label(reminder.durationMinutes)) }
        }
        // A borderless menu drops the label's fill and border: keep the chip drawn like its neighbours.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(reminder.status != .open)
        .help("Duration")
        .accessibilityLabel(Text("Duration"))
        .accessibilityValue(Text(verbatim: DurationPicker.label(reminder.durationMinutes)))
    }
}
