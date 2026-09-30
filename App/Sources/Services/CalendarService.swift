import EventKit
import Foundation
import TicklerCore

/// Mirrors reminders into one calendar, one way. The store stays the source of truth.
@MainActor
@Observable
final class CalendarService {
    enum Status: Equatable {
        case disabled
        case needsAccess
        case synced(Date)
        case failed(String)
    }

    private let eventStore = EKEventStore()
    private(set) var status: Status = .disabled
    private(set) var calendars: [EKCalendar] = []

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func prepare(calendarId: String?) async {
        guard calendarId != nil else {
            status = .disabled
            return
        }
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = await requestAccess()
        }
        loadCalendars()
    }

    func requestAccess() async -> Bool {
        let granted = await (try? eventStore.requestFullAccessToEvents()) ?? false
        loadCalendars()
        return granted
    }

    func loadCalendars() {
        guard hasAccess else {
            calendars = []
            return
        }
        calendars = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    func reconcile(store: ReminderStore, calendarId: String?) {
        do {
            guard let calendarId else {
                try removeAll(store: store)
                status = .disabled
                return
            }
            guard hasAccess else {
                status = .needsAccess
                return
            }
            guard let calendar = eventStore.calendar(withIdentifier: calendarId) else {
                status = .failed(String(localized: "The chosen calendar no longer exists. Pick another one in Settings."))
                return
            }
            let reminders = try store.syncCandidates()
            let links = try store.links(for: reminders.map(\.id))
            let actions = try CalendarPlanner.plan(
                reminders: reminders, links: links, mappings: store.calendarMappings(), calendarId: calendarId, now: Date()
            )
            for action in actions {
                try apply(action, calendar: calendar, links: links, store: store)
            }
            status = .synced(Date())
        } catch {
            eventStore.reset()
            status = .failed(error.localizedDescription)
        }
    }

    private func apply(_ action: CalendarAction, calendar: EKCalendar, links: [String: [ReminderLink]], store: ReminderStore) throws {
        switch action {
        case let .create(reminder, hash):
            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            fill(event, reminder: reminder, links: links[reminder.id] ?? [])
            try eventStore.save(event, span: .thisEvent, commit: true)
            try store.saveMapping(CalendarMapping(
                reminderId: reminder.id,
                eventIdentifier: event.eventIdentifier,
                calendarId: calendar.calendarIdentifier,
                syncedHash: hash
            ))
        case let .update(reminder, eventIdentifier, hash):
            // Saved one by one: the event identifier is only reliable once committed. An event deleted by hand comes back
            // only because the reminder itself changed.
            let event = eventStore.event(withIdentifier: eventIdentifier) ?? EKEvent(eventStore: eventStore)
            event.calendar = event.calendar ?? calendar
            fill(event, reminder: reminder, links: links[reminder.id] ?? [])
            try eventStore.save(event, span: .thisEvent, commit: true)
            try store.saveMapping(CalendarMapping(
                reminderId: reminder.id,
                eventIdentifier: event.eventIdentifier,
                calendarId: calendar.calendarIdentifier,
                syncedHash: hash
            ))
        case let .delete(eventIdentifier, reminderId):
            if let event = eventStore.event(withIdentifier: eventIdentifier) {
                try eventStore.remove(event, span: .thisEvent, commit: true)
            }
            try store.deleteMapping(reminderId: reminderId)
        }
    }

    private func removeAll(store: ReminderStore) throws {
        let mappings = try store.calendarMappings()
        guard !mappings.isEmpty else { return }
        if hasAccess {
            for mapping in mappings {
                if let event = eventStore.event(withIdentifier: mapping.eventIdentifier) {
                    try eventStore.remove(event, span: .thisEvent, commit: true)
                }
            }
        }
        for mapping in mappings {
            try store.deleteMapping(reminderId: mapping.reminderId)
        }
    }

    private func fill(_ event: EKEvent, reminder: Reminder, links: [ReminderLink]) {
        event.title = reminder.title
        event.startDate = reminder.dueAt
        event.endDate = reminder.dueAt.addingTimeInterval(15 * 60)
        event.availability = .free
        event.alarms = nil
        event.url = URL(string: "\(Tickler.urlScheme)://open/\(reminder.id)")
        let linkLines = links.map { "\($0.label): \($0.url)" }
        event.notes = ([reminder.notes] + (linkLines.isEmpty ? [] : ["", linkLines.joined(separator: "\n")]))
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
