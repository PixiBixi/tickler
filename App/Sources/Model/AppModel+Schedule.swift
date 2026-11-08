import Foundation
import TicklerCore

@MainActor
extension AppModel {
    // MARK: Scheduling

    private static let busyRefreshSeconds: TimeInterval = 15 * 60

    /// Launch, wake, `EKEventStoreChanged` and a new calendar selection ask for a fresh busy copy on the next run.
    func markBusyDirty() {
        busyDirty = true
        requestReconcile()
    }

    /// Replans before the notification step; `open` is reloaded when moves were written so notifications use new dates.
    func runScheduler(store: ReminderStore) async {
        guard let schedule = try? store.schedule() else { return }
        let dirty = busyDirty || lastBusyIds != schedule.busyCalendarIds
        let wroteBusy = refreshBusy(store: store, schedule: schedule, dirty: dirty)
        // Still dirty only when access exists but the write failed; without access there is nothing to retry.
        busyDirty = dirty && !wroteBusy && calendarSync.hasAccess && !isDemo
        lastBusyIds = schedule.busyCalendarIds
        let cause = pendingScheduleCause ?? (dirty ? .calendar : .routine)
        pendingScheduleCause = nil
        let created = pendingNewReminderId
        pendingNewReminderId = nil
        guard let outcome = try? ScheduleRunner.run(
            store: store, now: Date(), calendar: calendar, cause: cause, touched: created, touchedIsNew: created != nil,
            freshBusy: wroteBusy
        ) else { return }
        if !outcome.moves.isEmpty {
            reload()
        }
        await notifyNewConflicts(outcome.conflicts, store: store)
    }

    /// No chosen calendar is a real empty copy, written whatever the access. Chosen calendars that cannot be read write
    /// nothing, so the CLI sees the copy age instead of "no meetings".
    private func refreshBusy(store: ReminderStore, schedule: WorkSchedule, dirty: Bool) -> Bool {
        let ids = schedule.busyCalendarIds
        guard !isDemo, ids.isEmpty || calendarSync.hasAccess else { return false }
        let now = Date()
        let age = (try? store.busySnapshotAt()).flatMap(\.self).map { now.timeIntervalSince($0) }
        guard dirty || age.map({ $0 > Self.busyRefreshSeconds }) != false else { return false }
        var intervals: [DateInterval] = []
        if !ids.isEmpty {
            let horizon = WorkingTime(schedule: schedule, calendar: calendar).addingWorkingDays(30, to: now)
            let end = horizon ?? now.addingTimeInterval(60 * 86400)
            guard let read = calendarSync.busyIntervals(calendarIds: ids, from: calendar.startOfDay(for: now), to: end) else {
                return false
            }
            intervals = read
        }
        return (try? store.replaceBusy(intervals, at: now)) != nil
    }

    private func notifyNewConflicts(_ conflicts: [ScheduleConflict], store: ReminderStore) async {
        guard !conflicts.isEmpty, let fresh = try? store.recordConflicts(conflicts, at: Date()), !fresh.isEmpty else { return }
        let byId = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        await notifications.notifyConflicts(fresh, reminders: byId)
    }
}
