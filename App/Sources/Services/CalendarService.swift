import AppKit
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

    /// Stored rather than computed: EventKit's status is not observable, and Settings must switch once access is granted.
    private(set) var hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess

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

    /// Asked once by macOS; refused or write-only access can only be changed in System Settings.
    func requestOrOpenSettings() async {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = await requestAccess()
        } else if !hasAccess, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        loadCalendars()
    }

    var isRefused: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status != .notDetermined && status != .fullAccess
    }

    func requestAccess() async -> Bool {
        let granted = await (try? eventStore.requestFullAccessToEvents()) ?? false
        AppModel.shared.bringToFront()
        loadCalendars()
        return granted
    }

    func loadCalendars() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
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
            // One event that cannot be written must not block the others; its mapping stays and it is retried next time.
            var failures: [String] = []
            for action in actions {
                do {
                    try apply(action, calendar: calendar, links: links, store: store)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if let first = failures.first {
                status = .failed(String(localized: "\(failures.count) calendar events could not be written: \(first)"))
            } else {
                status = .synced(Date())
            }
        } catch {
            eventStore.reset()
            status = .failed(error.localizedDescription)
        }
    }

    private func apply(_ action: CalendarAction, calendar: EKCalendar, links: [String: [ReminderLink]], store: ReminderStore) throws {
        switch action {
        case let .create(reminder, hash):
            // A previous run may have saved the event and failed before recording it: reuse it rather than duplicate it.
            let event = findEvent(reminderId: reminder.id, in: calendar) ?? EKEvent(eventStore: eventStore)
            if event.calendar == nil {
                event.calendar = calendar
            }
            try write(event, reminder: reminder, links: links[reminder.id] ?? [], hash: hash, store: store)
        case let .update(reminder, eventIdentifier, hash):
            // An event deleted by hand comes back only because the reminder itself changed.
            let event = eventStore.event(withIdentifier: eventIdentifier)
                ?? findEvent(reminderId: reminder.id, in: calendar)
                ?? EKEvent(eventStore: eventStore)
            if event.calendar == nil {
                event.calendar = calendar
            }
            try write(event, reminder: reminder, links: links[reminder.id] ?? [], hash: hash, store: store)
        case let .delete(eventIdentifier, reminderId):
            let owner = eventStore.calendars(for: .event)
            if let event = eventStore.event(withIdentifier: eventIdentifier) ?? owner.lazy.compactMap({ self.findEvent(
                reminderId: reminderId,
                in: $0
            ) }).first {
                try eventStore.remove(event, span: .thisEvent, commit: true)
            }
            try store.deleteMapping(reminderId: reminderId)
        }
    }

    /// Saved one by one: the event identifier is only reliable once committed.
    private func write(_ event: EKEvent, reminder: Reminder, links: [ReminderLink], hash: String, store: ReminderStore) throws {
        fill(event, reminder: reminder, links: links)
        try eventStore.save(event, span: .thisEvent, commit: true)
        try store.saveMapping(CalendarMapping(
            reminderId: reminder.id,
            eventIdentifier: event.eventIdentifier,
            calendarId: event.calendar.calendarIdentifier,
            syncedHash: hash
        ))
    }

    /// The event carrying this reminder's marker, for when its stored identifier went stale.
    private func findEvent(reminderId: String, in calendar: EKCalendar) -> EKEvent? {
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-CalendarPlanner.pastWindow - 86400),
            end: now.addingTimeInterval(CalendarPlanner.futureWindow + 86400),
            calendars: [calendar]
        )
        return eventStore.events(matching: predicate).first {
            CalendarMarker.reminderId(url: $0.url, notes: $0.notes) == reminderId
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
        event.url = URL(string: CalendarMarker.link(for: reminder.id))
        event.notes = CalendarMarker.notes(for: reminder, links: links)
    }
}
