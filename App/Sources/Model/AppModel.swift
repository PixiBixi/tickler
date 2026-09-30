import AppKit
import SwiftUI
import TicklerCore

enum SidebarFilter: Hashable {
    case today
    case week
    case overdue
    case all
    case done
    case day(Date)
    case project(String)
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

struct ReminderGroup: Identifiable {
    let bucket: DueBucket?
    let reminders: [Reminder]
    var id: String {
        bucket?.rawValue ?? "done"
    }
}

/// The app's single source of UI state. Reads come from the shared SQLite file; every write reconciles
/// notifications and the calendar right away.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let preferences = Preferences()
    let notifications = NotificationService()
    let calendarSync = CalendarService()
    private(set) var store: ReminderStore?
    private(set) var loadError: String?

    private(set) var open: [Reminder] = []
    private(set) var done: [Reminder] = []
    private(set) var links: [String: [ReminderLink]] = [:]
    private(set) var runningSessions: Set<String> = []
    private(set) var now = Date()

    var filter: SidebarFilter = .today
    var selection: String?
    var search = ""
    var showQuickAdd = false
    var focusDateField = false
    var prefilledDateText: String?
    var toast: Toast?

    /// Set by the first view that appears: AppKit code cannot open a SwiftUI window by itself.
    var openMainWindow: (() -> Void)?

    private var observer: ChangeObserver?
    private var ticker: Timer?
    private var toastTask: Task<Void, Never>?
    private let calendar = Calendar.current

    private init() {
        do {
            // The app does not post change notifications for its own writes: it reconciles directly.
            store = try ReminderStore(database: TicklerDatabase(path: TicklerDatabase.defaultPath()), onChange: {})
        } catch {
            loadError = String(describing: error)
        }
    }

    func start() {
        reload()
        observer = ChangeObserver {
            Task { @MainActor in AppModel.shared.externalChange() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.externalChange() }
        }
        notifications.setUp()
        Task {
            await calendarSync.prepare(calendarId: preferences.calendarId)
            await reconcile(catchUp: true)
        }
    }

    // MARK: Loading

    func reload() {
        guard let store else { return }
        do {
            open = try store.list(ReminderFilter(due: .all))
            done = try Array(store.list(ReminderFilter(due: .all, status: .done)).prefix(100))
            links = try store.links(for: (open + done).map(\.id))
            now = Date()
            refreshSessions()
        } catch {
            showError(String(describing: error))
        }
    }

    private func externalChange() {
        reload()
        Task { await reconcile(catchUp: true) }
    }

    /// Only moves the clock: relative times and overdue colors follow. Session scans stay on reload, they walk the process table.
    private func tick() {
        now = Date()
    }

    func reconcile(catchUp: Bool = false) async {
        guard let store else { return }
        await notifications.reconcile(reminders: open, links: links)
        if catchUp {
            let notified = await notifications.catchUp(reminders: open, links: links)
            if !notified.isEmpty {
                try? store.markNotified(notified, at: Date())
                reload()
            }
        }
        calendarSync.reconcile(store: store, calendarId: preferences.calendarId)
    }

    private func refreshSessions() {
        let resumer = SessionResumer(driver: WezTermDriver(binary: URL(fileURLWithPath: "/usr/bin/false")))
        let ids = Set(open.compactMap(\.sessionId))
        runningSessions = ids.filter { resumer.isRunning(sessionId: $0) }
    }

    // MARK: Derived state

    var overdueCount: Int {
        open.count { $0.dueAt < now }
    }

    var todayCount: Int {
        open.count { $0.dueAt < startOfTomorrow }
    }

    var startOfTomorrow: Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    }

    var nextReminder: Reminder? {
        open.first { $0.dueAt >= now }
    }

    var selectedReminder: Reminder? {
        guard let selection else { return nil }
        return (open + done).first { $0.id == selection }
    }

    var projects: [(name: String, count: Int)] {
        let names = Dictionary(grouping: open.compactMap(\.project), by: { $0 })
        return names.map { ($0.key, $0.value.count) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func count(for filter: SidebarFilter) -> Int {
        reminders(for: filter).count
    }

    func reminders(for filter: SidebarFilter) -> [Reminder] {
        switch filter {
        case .today: open.filter { $0.dueAt < startOfTomorrow }
        case .week: open.filter { $0.dueAt < now.addingTimeInterval(7 * 86400) }
        case .overdue: open.filter { $0.dueAt < now }
        case .all: open
        case .done: done
        case let .day(day): open.filter { calendar.isDate($0.dueAt, inSameDayAs: day) }
        case let .project(name): open.filter { $0.project == name }
        }
    }

    var visibleGroups: [ReminderGroup] {
        var items = reminders(for: filter)
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) }
        }
        if filter == .done {
            return items.isEmpty ? [] : [ReminderGroup(bucket: nil, reminders: items)]
        }
        let grouped = Dictionary(grouping: items) { DueBucket.of($0.dueAt, now: now, calendar: calendar) }
        return DueBucket.allCases.compactMap { bucket in grouped[bucket].map { ReminderGroup(bucket: bucket, reminders: $0) } }
    }

    func links(of reminder: Reminder) -> [ReminderLink] {
        links[reminder.id] ?? []
    }

    // MARK: Actions

    func reveal(_ id: String) {
        guard let reminder = try? store?.get(id) else {
            showError(String(localized: "No reminder with id \(id)."))
            return
        }
        filter = reminder.status == .done ? .done : .all
        selection = id
        openMainWindow?()
    }

    func markDone(_ id: String) {
        perform {
            let reminder = try $0.markDone(id)
            await self.notifications.removeDelivered(reminderId: id)
            return String(localized: "Done: \(reminder.title)")
        }
    }

    func markSelectedDone() {
        if let id = selection {
            markDone(id)
        }
    }

    func snooze(_ id: String, preset: SnoozePreset) {
        guard let date = preset.date(from: Date()) else { return }
        reschedule(id, to: date)
    }

    func reschedule(_ id: String, to date: Date) {
        perform {
            try $0.reschedule(id, to: date)
            await self.notifications.removeDelivered(reminderId: id)
            return String(localized: "Moved to \(Format.dueLabel(date, now: Date()))")
        }
    }

    func update(_ id: String, title: String? = nil, notes: String? = nil) {
        perform {
            try $0.update(id, title: title, notes: notes)
            return nil
        }
    }

    func delete(_ id: String) {
        perform {
            try $0.delete(id)
            await self.notifications.removeDelivered(reminderId: id)
            return String(localized: "Reminder deleted")
        }
        if selection == id {
            selection = nil
        }
    }

    func add(title: String, notes: String, dueAt: Date) {
        perform {
            let reminder = try $0.add(ReminderDraft(title: title, notes: notes, dueAt: dueAt, source: .human))
            self.selection = reminder.id
            return String(localized: "Added for \(Format.dueLabel(dueAt, now: Date()))")
        }
    }

    func resumeSelected() {
        if let reminder = selectedReminder {
            resume(reminder)
        }
    }

    func resume(_ reminder: Reminder) {
        guard let sessionId = reminder.sessionId else { return }
        guard let binary = WezTermDriver.resolveBinary(configured: preferences.weztermPath) else {
            showError(String(localized: "WezTerm was not found. Set its path in Settings."))
            return
        }
        let cwd = reminder.cwd
        Task {
            let result = await Task.detached {
                Result { try SessionResumer(driver: WezTermDriver(binary: binary)).resume(sessionId: sessionId, fallbackCwd: cwd) }
            }.value
            switch result {
            case .success(.focused):
                showToast(String(localized: "Session brought to the front"))
            case .success:
                showToast(String(localized: "Session reopened in WezTerm"))
            case let .failure(error):
                showError(String(describing: error))
            }
            refreshSessions()
        }
    }

    func open(_ link: ReminderLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Toasts

    func showToast(_ message: String) {
        present(Toast(message: message, isError: false))
    }

    func showError(_ message: String) {
        present(Toast(message: message, isError: true))
    }

    private func present(_ toast: Toast) {
        withAnimation(.easeOut(duration: 0.2)) { self.toast = toast }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(toast.isError ? 6 : 3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        }
    }

    /// Runs a store write, then reloads and reconciles. The closure returns the confirmation to show, if any.
    private func perform(_ work: @escaping (ReminderStore) async throws -> String?) {
        guard let store else { return }
        Task {
            do {
                let message = try await work(store)
                reload()
                await reconcile()
                if let message {
                    showToast(message)
                }
            } catch {
                showError(String(describing: error))
            }
        }
    }
}
