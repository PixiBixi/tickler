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

    func refreshSettings() async {
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized
        usesBanners = settings.alertStyle == .banner
    }

    func reconcile(reminders: [Reminder], links: [String: [ReminderLink]]) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
            .filter { !$0.hasPrefix(NotificationCategory.summaryIdentifier) }
        let plan = NotificationPlanner.plan(reminders: reminders, links: links, pendingIds: Set(pending), now: Date())
        center.removePendingNotificationRequests(withIdentifiers: plan.remove)
        for planned in plan.add {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: planned.reminder.dueAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: planned.id,
                content: content(for: planned.reminder, category: planned.category),
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Returns the ids of the reminders it notified, for the model to record.
    func catchUp(reminders: [Reminder], links: [String: [ReminderLink]]) async -> [String] {
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        switch NotificationPlanner.catchUp(reminders: reminders, alreadyShownIds: Set(delivered + pending), now: Date()) {
        case .none:
            return []
        case let .individual(missed):
            for reminder in missed {
                let category = NotificationCategory.for(links: links[reminder.id] ?? [])
                let request = UNNotificationRequest(
                    identifier: NotificationPlanner.requestId(for: reminder),
                    content: content(for: reminder, category: category),
                    trigger: nil
                )
                try? await center.add(request)
            }
            return missed.map(\.id)
        case let .summary(missed):
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(missed.count) overdue reminders")
            content.body = missed.prefix(4).map(\.title).joined(separator: "\n")
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.summaryIdentifier
            let request = UNNotificationRequest(
                identifier: "\(NotificationCategory.summaryIdentifier)@\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
            return missed.map(\.id)
        }
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
        content.body = Format.preview(reminder.notes)
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
            return UNNotificationCategory(identifier: category.rawValue, actions: actions, intentIdentifiers: [], options: [])
        })
        categories.insert(UNNotificationCategory(
            identifier: NotificationCategory.summaryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        ))
        return categories
    }

    fileprivate func handle(action: String, reminderId: String?, text: String?) {
        let model = AppModel.shared
        guard let reminderId, let reminder = model.open.first(where: { $0.id == reminderId }) ?? (try? model.store?.get(reminderId)) else {
            model.openMainWindow?()
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
        let reminderId = notification.request.content.userInfo["reminderId"] as? String
        await MainActor.run {
            if let reminderId {
                try? AppModel.shared.store?.markNotified([reminderId], at: Date())
            }
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let reminderId = response.notification.request.content.userInfo["reminderId"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if let reminderId {
                try? AppModel.shared.store?.markNotified([reminderId], at: Date())
            }
            if action == UNNotificationDefaultActionIdentifier {
                if let reminderId {
                    AppModel.shared.reveal(reminderId)
                } else {
                    AppModel.shared.openMainWindow?()
                }
            } else if action != UNNotificationDismissActionIdentifier {
                AppModel.shared.notifications.handle(action: action, reminderId: reminderId, text: text)
            }
        }
    }
}
