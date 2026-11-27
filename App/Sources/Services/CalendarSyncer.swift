import EventKit
import Foundation
import TicklerCore

/// The calendar sync's EventKit and SQLite work, off the main actor on its own event store (#25).
/// Its only caller runs from `AppModel.requestReconcile`, which already allows one sync at a time.
actor CalendarSyncer {
    typealias Status = CalendarService.Status

    /// Never the main actor's store: EventKit objects cannot cross actors. Created on first use.
    private var eventStore: EKEventStore?

    func reconcile(store: ReminderStore, calendarId: String?, hasAccess: Bool) -> Status {
        do {
            guard let calendarId else {
                try removeAll(store: store, hasAccess: hasAccess)
                return .disabled
            }
            guard hasAccess else { return .needsAccess }
            let events = currentStore()
            guard let calendar = events.calendar(withIdentifier: calendarId) else { throw CalendarSyncError.calendarGone }
            let reminders = try store.syncCandidates()
            let links = try store.links(for: reminders.map(\.id))
            let actions = try CalendarPlanner.plan(
                reminders: reminders, links: links, mappings: store.calendarMappings(), calendarId: calendarId, now: Date()
            )
            let failures = try apply(actions, calendar: calendar, calendarId: calendarId, links: links, store: store)
            if let first = failures.first {
                return .failed(String(localized: "\(failures.count) calendar events could not be written: \(first)"))
            }
            return .synced(Date())
        } catch {
            eventStore?.reset()
            return .failed(error.localizedDescription)
        }
    }

    /// #25: one commit for the whole run. A failed commit wrote nothing: the run is replayed with one commit per event,
    /// so one event that cannot be written does not block the others. Mappings are saved only once events are committed.
    private func apply(
        _ actions: [CalendarAction], calendar: EKCalendar, calendarId: String, links: [String: [ReminderLink]], store: ReminderStore
    ) throws -> [String] {
        guard !actions.isEmpty else { return [] }
        let events = currentStore()
        var pass = SyncPass(eventStore: events, calendar: calendar, links: links, commitEach: false)
        pass.run(actions)
        do {
            try events.commit()
        } catch {
            events.reset()
            // The reset invalidates every fetched object, the calendar included.
            guard let refetched = events.calendar(withIdentifier: calendarId) else { throw CalendarSyncError.calendarGone }
            pass = SyncPass(eventStore: events, calendar: refetched, links: links, commitEach: true)
            pass.run(actions)
        }
        try store.updateMappings(saving: pass.mappings, deleting: pass.unmapped)
        return pass.failures
    }

    private func removeAll(store: ReminderStore, hasAccess: Bool) throws {
        let mappings = try store.calendarMappings()
        guard !mappings.isEmpty else { return }
        if hasAccess {
            let events = currentStore()
            for mapping in mappings {
                if let event = events.event(withIdentifier: mapping.eventIdentifier) {
                    try events.remove(event, span: .thisEvent, commit: false)
                }
            }
            try events.commit()
        }
        try store.updateMappings(saving: [], deleting: mappings.map(\.reminderId))
    }

    private func currentStore() -> EKEventStore {
        if let eventStore {
            return eventStore
        }
        let created = EKEventStore()
        eventStore = created
        return created
    }
}

private enum CalendarSyncError: LocalizedError {
    case calendarGone

    var errorDescription: String? {
        String(localized: "The chosen calendar no longer exists. Pick another one in Settings.")
    }
}

/// One pass over the planned actions. Each marker index is one query, built on first use and reused by every action (#25).
private final class SyncPass {
    private let eventStore: EKEventStore
    private let calendar: EKCalendar
    private let links: [String: [ReminderLink]]
    private let commitEach: Bool
    private lazy var inCalendar = index(calendars: [calendar])
    private lazy var anywhere = index(calendars: nil)
    /// Each saved event with its mapping, whose identifier and calendar are filled in after the commit.
    private var written: [(event: EKEvent, mapping: CalendarMapping)] = []
    private(set) var unmapped: [String] = []
    private(set) var failures: [String] = []

    init(eventStore: EKEventStore, calendar: EKCalendar, links: [String: [ReminderLink]], commitEach: Bool) {
        self.eventStore = eventStore
        self.calendar = calendar
        self.links = links
        self.commitEach = commitEach
    }

    /// Read after the commit: the event identifier is only reliable once committed. A missing one is found again by its marker.
    var mappings: [CalendarMapping] {
        written.compactMap { event, mapping in
            guard let identifier = event.eventIdentifier, let calendar = event.calendar else { return nil }
            var mapping = mapping
            mapping.eventIdentifier = identifier
            mapping.calendarId = calendar.calendarIdentifier
            return mapping
        }
    }

    func run(_ actions: [CalendarAction]) {
        for action in actions {
            do {
                try apply(action)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
    }

    private func apply(_ action: CalendarAction) throws {
        switch action {
        case let .create(reminder, hash):
            // A previous run may have saved the event and failed before recording it: reuse it rather than duplicate it.
            try write(inCalendar[reminder.id] ?? EKEvent(eventStore: eventStore), reminder: reminder, hash: hash)
        case let .update(reminder, eventIdentifier, hash):
            // An event deleted by hand comes back only because the reminder itself changed.
            let event = eventStore.event(withIdentifier: eventIdentifier) ?? inCalendar[reminder.id] ?? EKEvent(eventStore: eventStore)
            try write(event, reminder: reminder, hash: hash)
        case let .delete(eventIdentifier, reminderId):
            // #25: the mapping goes even when the removal fails (read-only calendar), or every run would scan for it again.
            unmapped.append(reminderId)
            if let event = eventStore.event(withIdentifier: eventIdentifier) ?? anywhere[reminderId] {
                try eventStore.remove(event, span: .thisEvent, commit: commitEach)
            }
        }
    }

    private func write(_ event: EKEvent, reminder: Reminder, hash: String) throws {
        if event.calendar == nil {
            event.calendar = calendar
        }
        fill(event, reminder: reminder, links: links[reminder.id] ?? [])
        try eventStore.save(event, span: .thisEvent, commit: commitEach)
        written.append((event, CalendarMapping(reminderId: reminder.id, eventIdentifier: "", calendarId: "", syncedHash: hash)))
    }

    /// The events carrying a marker in the search window; `nil` calendars means all of them, for a stale delete.
    private func index(calendars: [EKCalendar]?) -> [String: EKEvent] {
        let window = CalendarPlanner.searchWindow(now: Date())
        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        return CalendarMarker.index(eventStore.events(matching: predicate)) { ($0.url, $0.notes) }
    }

    private func fill(_ event: EKEvent, reminder: Reminder, links: [ReminderLink]) {
        event.title = reminder.title
        event.startDate = reminder.dueAt
        event.endDate = reminder.dueAt.addingTimeInterval(Double(reminder.durationMinutes) * 60)
        event.availability = .free
        event.alarms = nil
        event.url = URL(string: CalendarMarker.link(for: reminder.id))
        event.notes = CalendarMarker.notes(for: reminder, links: links)
    }
}
