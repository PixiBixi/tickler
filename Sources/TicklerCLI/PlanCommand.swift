import ArgumentParser
import Foundation
import TicklerCore

struct PlanCommand: TicklerSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Show a day: busy time, reminders and free time. Reads what is stored, plans nothing."
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "The day, YYYY-MM-DD. Default: today.") var date: String?
    @Flag(help: "Print JSON.") var json = false

    private struct Block {
        enum Kind: String { case busy, reminder, free }

        var start: Date
        var end: Date
        var kind: Kind
        var title: String?
        var fixed = false
        var late = false
    }

    func execute(_ context: CLIContext) throws {
        let day = try parseDay(context)
        let store = try context.openStore(options)
        let blocks = try blocks(on: day, context: context, store: store)
        if json {
            let items = blocks.map { block in
                ["start": context.clock(block.start), "end": context.clock(block.end), "kind": block.kind.rawValue]
                    .merging(block.title.map { ["title": $0] } ?? [:]) { first, _ in first }
            }
            try context.stdout.line(context.encodeJSON(items))
            return
        }
        for block in blocks {
            context.stdout.line("\(context.clock(block.start))-\(context.clock(block.end)) \(label(block))")
        }
    }

    private func parseDay(_ context: CLIContext) throws -> Date {
        guard let date else { return context.calendar.startOfDay(for: context.now()) }
        guard date.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil,
              let day = StrictDate.parse(date + " 00:00", calendar: context.calendar)
        else {
            throw CLIError.usage("the day expects YYYY-MM-DD, got \"\(date)\"")
        }
        return day
    }

    private func label(_ block: Block) -> String {
        switch block.kind {
        case .busy: return "busy"
        case .free: return "free"
        case .reminder:
            let marks = [block.fixed ? "(fixed)" : nil, block.late ? "(late)" : nil].compactMap(\.self)
            return ([block.title ?? ""] + marks).joined(separator: " ")
        }
    }

    private func blocks(on day: Date, context: CLIContext, store: ReminderStore) throws -> [Block] {
        let calendar = context.calendar
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        let span = DateInterval(start: day, end: nextDay)
        var blocks: [Block] = try store.busy().compactMap { interval in
            guard let clipped = interval.intersection(with: span), clipped.duration > 0 else { return nil }
            return Block(start: clipped.start, end: clipped.end, kind: .busy)
        }
        let open = try store.list(ReminderFilter(due: .all, status: .open))
        for reminder in open where span.contains(reminder.dueAt) && !reminder.isWaiting {
            let end = reminder.dueAt.addingTimeInterval(TimeInterval(reminder.durationMinutes * 60))
            blocks.append(Block(
                start: reminder.dueAt, end: end, kind: .reminder, title: reminder.title.displaySafeLine,
                fixed: reminder.holdsItsTime, late: reminder.isLate
            ))
        }
        blocks.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        guard let window = try WorkingTime(schedule: store.schedule(), calendar: calendar).window(on: day) else { return blocks }
        return withFree(blocks, in: window)
    }

    private func withFree(_ blocks: [Block], in window: DateInterval) -> [Block] {
        var result: [Block] = []
        var cursor = window.start
        for block in blocks {
            if block.start > cursor, cursor < window.end {
                result.append(Block(start: cursor, end: min(block.start, window.end), kind: .free))
            }
            result.append(block)
            cursor = max(cursor, block.end)
        }
        if cursor < window.end {
            result.append(Block(start: cursor, end: window.end, kind: .free))
        }
        return result
    }
}
