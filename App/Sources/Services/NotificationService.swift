import AppKit
import TicklerCore
@preconcurrency import UserNotifications

/// Applies `NotificationPlanner` to UNUserNotificationCenter and routes notification actions back to the model.
@MainActor
@Observable
final class NotificationService: NSObject {
    enum Action: String {
        case resume = "tickler.resume"
        case snooze15 = "tickler.snooze.15m"
        case snooze60 = "tickler.snooze.1h"
        case tomorrow = "tickler.snooze.tomorrow"
        case reschedule = "tickler.reschedule"
        case openTicket = "tickler.open.ticket"
        case openSlack = "tickler.open.slack"
        case openLink = "tickler.open.link"
        case done = "tickler.done"
    }

    private let center = UNUserNotificationCenter.current()
    private(set) var authorized = false
    /// Banner style hides the actions after a few seconds; the window suggests switching to Alerts.
    private(set) var usesBanners = false

    func setUp() {
        center.delegate = self
        center.setNotificationCategories(Self.categories())
        Task {
            authorized = await (try? center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshSettings()
        }
    }

    private(set) var status: UNAuthorizationStatus = .notDetermined

    func refreshSettings() async {
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        authorized = [.authorized, .provisional].contains(settings.authorizationStatus)
        usesBanners = settings.alertStyle == .banner
    }

    /// macOS shows its prompt only once: after a refusal, the only way is System Settings.
    func requestOrOpenSettings() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            AppModel.shared.bringToFront()
        } else if let url =
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Tickler.bundleIdentifier)")
        {
            NSWorkspace.shared.open(url)
        }
        await refreshSettings()
    }

    /// Applies the plan and clears banners of reminders done, deleted or moved since. Returns the reminders whose
    /// banner is on screen but not yet recorded as notified: the app was in the background when they fired.
    func reconcile(reminders: [Reminder], links: [String: [ReminderLink]]) async -> [String] {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
            .filter { !$0.hasPrefix(NotificationCategory.summaryIdentifier) }
        let plan = NotificationPlanner.plan(reminders: reminders, links: links, pendingIds: Set(pending), now: Date())
        center.removePendingNotificationRequests(withIdentifiers: plan.remove)
        for planned in plan.add {
            // With a time zone the components name an absolute instant: travel does not shift the reminder.
            let components = Calendar.current.dateComponents(in: .current, from: planned.reminder.dueAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: planned.id,
                content: content(for: planned.reminder, category: planned.category),
                trigger: trigger
            )
            try? await center.add(request)
        }
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: NotificationPlanner.staleDelivered(
            deliveredIds: delivered,
            reminders: reminders
        ))
        let shown = Set(delivered)
        return reminders.filter { $0.notifiedAt == nil && shown.contains(NotificationPlanner.requestId(for: $0)) }.map(\.id)
    }

    /// Returns the ids of the reminders it notified, for the model to record.
    func catchUp(reminders: [Reminder], links: [String: [ReminderLink]]) async -> [String] {
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let plan = NotificationPlanner.catchUp(reminders: reminders, alreadyShownIds: Set(delivered + pending), now: Date())
        var individual: [Reminder] = []
        var summary: [Reminder] = []
        switch plan {
        case .none: return []
        case let .individual(missed): individual = missed
        case let .summary(missed): summary = missed
        case let .summaryAndIndividual(summarized, single): (summary, individual) = (summarized, single)
        }
        for reminder in individual {
            let category = NotificationCategory.for(links: links[reminder.id] ?? [])
            let request = UNNotificationRequest(
                identifier: NotificationPlanner.requestId(for: reminder),
                content: content(for: reminder, category: category),
                trigger: nil
            )
            try? await center.add(request)
        }
        if !summary.isEmpty {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(summary.count) overdue reminders")
            content.body = summary.prefix(4).map(\.title).joined(separator: "\n")
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.summaryIdentifier
            let request = UNNotificationRequest(
                identifier: "\(NotificationCategory.summaryIdentifier)@\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
        return (individual + summary).map(\.id)
    }

    /// "Claude added a reminder": one banner each, a single summary beyond three (an import, a burst of follow-ups).
    func announce(_ added: [Reminder]) async {
        guard !added.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.threadIdentifier = NotificationCategory.announcementPrefix
        if added.count <= 3 {
            for reminder in added {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "New reminder: \(reminder.title)")
                content.subtitle = [Format.dueLabel(reminder.dueAt, now: Date()), reminder.project].compactMap(\.self)
                    .joined(separator: " · ")
                content.body = Format.preview(reminder.notes)
                content.threadIdentifier = NotificationCategory.announcementPrefix
                content.userInfo = ["reminderId": reminder.id]
                let request = UNNotificationRequest(
                    identifier: "\(NotificationCategory.announcementPrefix)@\(reminder.id)",
                    content: content,
                    trigger: nil
                )
                try? await center.add(request)
            }
            return
        }
        content.title = String(localized: "\(added.count) new reminders")
        content.body = added.prefix(4).map(\.title).joined(separator: "\n")
        let request = UNNotificationRequest(
            identifier: "\(NotificationCategory.announcementPrefix)@batch-\(Int(Date().timeIntervalSince1970))", content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func removeDelivered(reminderId: String) async {
        let ids = await center.deliveredNotifications().map(\.request.identifier)
            .filter { NotificationPlanner.reminderId(fromRequestId: $0) == reminderId }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func content(for reminder: Reminder, category: NotificationCategory) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.subtitle = [Format.time(reminder.dueAt), reminder.project].compactMap(\.self).joined(separator: " · ")
        // The reason leads only on the firing itself; a later reschedule notifies like any reminder.
        let lead: String? = if let trigger = reminder.trigger {
            String(localized: "Still waiting: \(trigger)")
        } else if let reason = reminder.firedReason, reminder.firedAt == reminder.dueAt {
            reason
        } else {
            nil
        }
        content.body = [lead, Format.preview(reminder.notes)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
        content.sound = .default
        content.categoryIdentifier = category.rawValue
        content.threadIdentifier = "tickler"
        content.userInfo = ["reminderId": reminder.id]
        return content
    }

    static func categories() -> Set<UNNotificationCategory> {
        let resume = UNNotificationAction(
            identifier: Action.resume.rawValue,
            title: String(localized: "Resume Session"),
            options: [.foreground]
        )
        let snooze15 = UNNotificationAction(identifier: Action.snooze15.rawValue, title: String(localized: "Snooze 15 min"))
        let snooze60 = UNNotificationAction(identifier: Action.snooze60.rawValue, title: String(localized: "Snooze 1 hour"))
        let tomorrow = UNNotificationAction(identifier: Action.tomorrow.rawValue, title: String(localized: "Tomorrow 09:30"))
        let reschedule = UNTextInputNotificationAction(
            identifier: Action.reschedule.rawValue,
            title: String(localized: "Reschedule…"),
            textInputButtonTitle: String(localized: "Reschedule"),
            textInputPlaceholder: String(localized: "tomorrow 2pm, monday 10am, in 3h")
        )
        let ticket = UNNotificationAction(
            identifier: Action.openTicket.rawValue,
            title: String(localized: "Open Ticket"),
            options: [.foreground]
        )
        let slack = UNNotificationAction(
            identifier: Action.openSlack.rawValue,
            title: String(localized: "Open Slack Thread"),
            options: [.foreground]
        )
        let link = UNNotificationAction(identifier: Action.openLink.rawValue, title: String(localized: "Open Link"), options: [.foreground])
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: String(localized: "Mark Done"))

        var categories = Set(NotificationCategory.allCases.map { category in
            var actions = [resume, snooze15, snooze60, tomorrow, reschedule]
            if category.hasTicket {
                actions.append(ticket)
            }
            if category.hasSlack {
                actions.append(slack)
            }
            if category.hasLink {
                actions.append(link)
            }
            actions.append(done)
            // customDismissAction: clearing a banner counts as "seen", so catch-up does not show it again.
            return UNNotificationCategory(
                identifier: category.rawValue,
                actions: actions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        })
        categories.insert(UNNotificationCategory(
            identifier: NotificationCategory.summaryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        ))
        return categories
    }

    /// A banner left from before a done, delete or reschedule must not act on the reminder as it is now.
    fileprivate func handle(action: String, requestId: String, reminderId: String?, text: String?) {
        let model = AppModel.shared
        guard let reminderId, let reminder = try? model.store?.get(reminderId) else {
            model.showMainWindow()
            return
        }
        guard NotificationPlanner.isCurrent(requestId: requestId, reminder: reminder) else {
            model.reveal(reminderId)
            model.showToast(String(localized: "This notification is out of date: the reminder changed since."))
            return
        }
        let targets = LinkTargets(links: model.links(of: reminder))
        switch Action(rawValue: action) {
        case .resume: model.resume(reminder)
        case .snooze15: model.snooze(reminderId, preset: .fifteenMinutes)
        case .snooze60: model.snooze(reminderId, preset: .oneHour)
        case .tomorrow: model.snooze(reminderId, preset: .tomorrowMorning)
        case .reschedule: reschedule(reminder, text: text ?? "")
        case .openTicket: targets.ticket.map(model.open)
        case .openSlack: targets.slack.map(model.open)
        case .openLink: targets.other.map(model.open)
        case .done: model.markDone(reminderId)
        case nil: model.reveal(reminderId)
        }
    }

    /// Unparsable or past text opens the window on the date field with the text kept, rather than guessing.
    private func reschedule(_ reminder: Reminder, text: String) {
        let model = AppModel.shared
        let parser = DateParser(preferred: Format.locale.language.languageCode?.identifier ?? "en")
        if let date = parser.parse(text) {
            model.reschedule(reminder.id, to: date)
        } else {
            model.prefilledDateText = text
            model.focusDateField = true
            model.reveal(reminder.id)
            model.showError(String(localized: "Could not read the date “\(text)”."))
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let requestId = notification.request.identifier
        await MainActor.run { NotificationService.recordShown(requestId: requestId) }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let requestId = response.notification.request.identifier
        let reminderId = response.notification.request.content.userInfo["reminderId"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            NotificationService.recordShown(requestId: requestId)
            switch action {
            case UNNotificationDismissActionIdentifier:
                break
            case UNNotificationDefaultActionIdentifier:
                if let reminderId {
                    AppModel.shared.reveal(reminderId)
                } else {
                    AppModel.shared.showMainWindow()
                }
            default:
                AppModel.shared.notifications.handle(action: action, requestId: requestId, reminderId: reminderId, text: text)
            }
        }
    }

    /// Only a banner for the reminder's current time counts: an old one must not hide the next catch-up.
    @MainActor
    private static func recordShown(requestId: String) {
        let reminderId = NotificationPlanner.reminderId(fromRequestId: requestId)
        guard let store = AppModel.shared.store, let reminder = try? store.get(reminderId),
              NotificationPlanner.isCurrent(requestId: requestId, reminder: reminder) else { return }
        try? store.markNotified([reminderId], at: Date())
    }
}
