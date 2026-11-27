import AppKit
import EventKit
import Foundation
import TicklerCore

/// Mirrors reminders into one calendar, one way. The store stays the source of truth.
@MainActor
@Observable
final class CalendarService {
    enum Status: Equatable, Sendable {
        case disabled
        case needsAccess
        case synced(Date)
        case failed(String)
    }

    private let eventStore = EKEventStore()
    private let syncer = CalendarSyncer()
    private(set) var status: Status = .disabled
    private(set) var calendars: [EKCalendar] = []
    /// Every event calendar, read-only ones included: the planner only reads their busy times.
    private(set) var busyCandidates: [EKCalendar] = []

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
        // Completion form: the async one sends the main-actor store across isolation, an error before Swift 6.3.
        // @Sendable: EventKit calls back on its XPC queue, a main-actor closure would trap there. Do NOT remove.
        let granted = await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { @Sendable granted, _ in continuation.resume(returning: granted) }
        }
        AppModel.shared.bringToFront()
        loadCalendars()
        return granted
    }

    func loadCalendars() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else {
            calendars = []
            busyCandidates = []
            return
        }
        busyCandidates = eventStore.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
        calendars = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// Called on `EKEventStoreChanged`, which also fires for our own event writes: the caller must converge.
    @ObservationIgnored private var storeObserver: NSObjectProtocol?

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        storeObserver.map { NotificationCenter.default.removeObserver($0) }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { _ in
            Task { @MainActor in onChange() }
        }
    }

    /// Start and end only: no event text leaves this method. Skips all-day, free, declined and Tickler's own events.
    /// Nil when there is no access or none of the chosen calendars resolves: unknown, not "no meetings".
    func busyIntervals(calendarIds: [String], from start: Date, to end: Date) -> [DateInterval]? {
        guard hasAccess else { return nil }
        let chosen = calendarIds.compactMap { eventStore.calendar(withIdentifier: $0) }
        guard !chosen.isEmpty else { return nil }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: chosen)
        return eventStore.events(matching: predicate).filter(Self.blocksTime).compactMap { event in
            event.endDate > event.startDate ? DateInterval(start: event.startDate, end: event.endDate) : nil
        }
    }

    private static func blocksTime(_ event: EKEvent) -> Bool {
        if event.isAllDay || event.availability == .free || event.status == .canceled {
            return false
        }
        if CalendarMarker.reminderId(url: event.url, notes: event.notes) != nil {
            return false
        }
        return event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
    }

    /// #25: the EventKit and SQLite work runs on `CalendarSyncer`, only the status comes back to the main actor.
    func reconcile(store: ReminderStore, calendarId: String?) async {
        status = await syncer.reconcile(store: store, calendarId: calendarId, hasAccess: hasAccess)
    }
}
