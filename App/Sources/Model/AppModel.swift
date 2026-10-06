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
    let liveStatus = LiveStatusStore()
    let triggerWatcher = TriggerWatcher()
    private(set) var store: ReminderStore?
    private(set) var loadError: String?

    private(set) var open: [Reminder] = []
    private(set) var done: [Reminder] = []
    private(set) var links: [String: [ReminderLink]] = [:]
    private(set) var runningSessions: Set<String> = []
    private(set) var now = Date()

    var filter: SidebarFilter = .today {
        didSet {
            if filter == .today {
                stripWeek = 0
            }
        }
    }

    /// Weeks the day strip is moved by, negative for the past. Going back to Today resets it.
    var stripWeek = 0
    var selection: String?
    var search = ""
    var showQuickAdd = false
    /// Debug demo recordings: no calendar writes, canned live status, scripted typing in the new reminder sheet.
    let isDemo = ProcessInfo.processInfo.environment["TICKLER_DEMO"] != nil
    var demoTyping: (title: String, when: String)?
    var showOnboarding = false
    var focusDateField = false
    var prefilledDateText: String?
    var toast: Toast?

    /// Set by the first view that appears: AppKit code cannot open a SwiftUI window by itself.
    /// A reveal asked for before that (a notification click on a cold launch) waits for it.
    var openMainWindow: (() -> Void)? {
        didSet {
            if pendingWindowOpen, let openMainWindow {
                pendingWindowOpen = false
                openMainWindow()
            }
        }
    }

    private var pendingWindowOpen = false

    /// A system permission prompt takes focus away; once answered, nothing gives it back, and the window ends up behind others.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.contains(WindowID.main) == true && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    /// The global shortcut: window forward, sheet open, whatever app was in front.
    func quickAddFromAnywhere() {
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        showQuickAdd = true
    }

    func showMainWindow() {
        if let openMainWindow {
            openMainWindow()
        } else {
            pendingWindowOpen = true
        }
    }

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
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                AppModel.shared.reload()
                AppModel.shared.requestReconcile(catchUp: true)
                AppModel.shared.triggerWatcher.check()
            }
        }
        // Permissions granted in System Settings take effect when the user comes back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await AppModel.shared.notifications.refreshSettings()
                AppModel.shared.calendarSync.loadCalendars()
            }
        }
        GlobalHotKey.shared.setEnabled(preferences.globalShortcut)
        notifications.setUp()
        Task {
            await calendarSync.prepare(calendarId: preferences.calendarId)
            requestReconcile(catchUp: true)
        }
        triggerWatcher.start()
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

    /// A write from outside the app (Claude, the CLI): new reminders are announced if the user wants it.
    private func externalChange() {
        let before = Set((open + done).map(\.id))
        let waitingBefore = Set(open.filter(\.isWaiting).map(\.id))
        reload()
        if preferences.announceNewReminders, !isDemo {
            let added = NotificationPlanner.newlyAdded(previousIds: before, reminders: open)
            Task { await notifications.announce(added) }
        }
        requestReconcile()
        if !Set(open.filter(\.isWaiting).map(\.id)).isSubset(of: waitingBefore) {
            triggerWatcher.check()
        }
    }

    /// Moves the clock for relative times and overdue colors, and rereads the store in case a change signal was missed.
    private func tick() {
        reload()
    }

    // MARK: Reconciliation

    private var reconciling = false
    private var reconcileAgain = false
    private var catchUpRequested = false

    /// One reconciliation at a time: overlapping runs read the same pending state and add the same notification twice.
    /// Catch-up runs only at start and on wake, as a CLI write is not a missed notification.
    func requestReconcile(catchUp: Bool = false) {
        catchUpRequested = catchUpRequested || catchUp
        guard !reconciling else {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task {
            repeat {
                reconcileAgain = false
                let withCatchUp = catchUpRequested
                catchUpRequested = false
                await reconcileOnce(catchUp: withCatchUp)
            } while reconcileAgain || catchUpRequested
            reconciling = false
        }
    }

    private func reconcileOnce(catchUp: Bool) async {
        guard let store else { return }
        let alreadyDelivered = await notifications.reconcile(reminders: open, links: links)
        var notified = alreadyDelivered
        if catchUp {
            notified += await notifications.catchUp(reminders: open.filter { !alreadyDelivered.contains($0.id) }, links: links)
        }
        if !notified.isEmpty {
            try? store.markNotified(notified, at: Date())
            reload()
        }
        // Demo recordings never touch the user's real calendar.
        calendarSync.reconcile(store: store, calendarId: isDemo ? nil : preferences.calendarId)
    }

    /// Off the main actor: it walks the process table.
    private func refreshSessions() {
        let ids = Set(open.compactMap(\.sessionId))
        Task {
            let running = await Task.detached {
                SessionResumer(driver: WezTermDriver(binary: URL(fileURLWithPath: "/usr/bin/false"))).runningSessions(ids)
            }.value
            if running != runningSessions {
                runningSessions = running
            }
        }
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
        open.first { $0.dueAt >= now && DueBucket.of($0, now: now, calendar: calendar) != .waiting }
    }

    var selectedReminder: Reminder? {
        guard let selection else { return nil }
        return (open + done).first { $0.id == selection }
    }

    var projects: [(name: String, count: Int)] {
        let names = Dictionary(grouping: open.compactMap(\.project), by: { $0 })
        return names.map { ($0.key, $0.value.count) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Sidebar badges count what is left to do; only the Done view counts finished reminders.
    func count(for filter: SidebarFilter) -> Int {
        let items = reminders(for: filter)
        return filter == .done ? items.count : items.count { $0.status == .open }
    }

    func reminders(for filter: SidebarFilter) -> [Reminder] {
        switch filter {
        // Today matches the day view of today: what was done today stays listed under Done.
        case .today: open.filter { $0.dueAt < startOfTomorrow } + done.filter { calendar.isDateInToday($0.dueAt) }
        case .week: open.filter { $0.dueAt < now.addingTimeInterval(7 * 86400) }
        case .overdue: open.filter { $0.dueAt < now }
        case .all: open
        case .done: done
        case let .day(day): (open + done).filter { calendar.isDate($0.dueAt, inSameDayAs: day) }
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
        // Day views, today included, also list what was done that day, after what is still open.
        let finished = items.filter { $0.status == .done }
        let grouped = Dictionary(grouping: items.filter { $0.status == .open }) { DueBucket.of($0, now: now, calendar: calendar) }
        let openGroups = DueBucket.allCases.compactMap { bucket in grouped[bucket].map { ReminderGroup(bucket: bucket, reminders: $0) } }
        return openGroups + (finished.isEmpty ? [] : [ReminderGroup(bucket: nil, reminders: finished)])
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
        showMainWindow()
    }

    /// `tickler://open/<id>` reveals a reminder, `tickler://view/<filter>` opens the window on a sidebar view.
    func open(_ url: URL) {
        guard url.scheme == Tickler.urlScheme else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (url.host(), parts.first) {
        case let ("open", id?):
            reveal(id)
        case let ("view", name?):
            let views: [String: SidebarFilter] = ["today": .today, "week": .week, "overdue": .overdue, "all": .all, "done": .done]
            if let view = views[name] {
                filter = view
                selection = nil
            }
            showMainWindow()
        default:
            break
        }
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

    func update(_ id: String, title: String? = nil, notes: String? = nil, resumePrompt: String? = nil) {
        perform {
            try $0.update(id, title: title, notes: notes, resumePrompt: resumePrompt)
            return nil
        }
    }

    func setTrigger(_ id: String, _ trigger: Trigger?) {
        perform {
            try $0.setTrigger(id, trigger)
            return trigger == nil ? String(localized: "No longer waiting") : nil
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
        let driver = preferences.terminal.driver(weztermPath: preferences.weztermPath)
        let cwd = reminder.cwd
        let prompt = reminder.resumeMessage
        Task {
            let result = await Task.detached {
                Result { try SessionResumer(driver: driver).resume(sessionId: sessionId, fallbackCwd: cwd, prompt: prompt) }
            }.value
            switch result {
            case .success(.focused(_, typedPrompt: true)):
                showToast(String(localized: "Prompt typed in the session, press Return to send it"))
            case .success(.focused):
                if let prompt {
                    // The terminal cannot type into a running session (Ghostty): hand the prompt over the clipboard.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    showToast(String(localized: "Session brought to the front, prompt copied: paste it with ⌘V"))
                } else {
                    showToast(String(localized: "Session brought to the front"))
                }
            case .success:
                showToast(prompt == nil
                    ? String(localized: "Session reopened in the terminal")
                    : String(localized: "Session reopened, prompt sent to Claude"))
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
                requestReconcile()
                if let message {
                    showToast(message)
                }
            } catch {
                showError(String(describing: error))
            }
        }
    }
}
