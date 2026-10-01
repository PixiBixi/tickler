#if DEBUG
    import AppKit
    import SwiftUI
    import TicklerCore
    @preconcurrency import UserNotifications

    /// Debug builds only: `TICKLER_DEMO=1` plays a scripted tour of the app for a screen recording, on a demo database.
    @MainActor
    enum DemoDriver {
        static func startIfRequested() {
            guard AppModel.shared.isDemo else { return }
            let model = AppModel.shared
            model.preferences.bannerHintDismissed = true
            seedLiveStatus()
            let steps: [(Double, () -> Void)] = [
                (0.5, { placeWindow() }),
                (1.0, { model.filter = .today; model.selection = nil }),
                (3.0, { select("Merge the scaler rollout") }),
                (8.0, { select("Check Tempo ingestion") }),
                (11.0, { model.showQuickAdd = true }),
                (12.0, { type(title: "Chase Alice on the review of !87", when: "tomorrow 10am") }),
                (17.5, { finishQuickAdd() }),
                (19.0, { notify("Check Tempo ingestion") }),
                (24.0, { reschedule("Merge the scaler rollout") }),
                (29.0, { NSApp.terminate(nil) }),
            ]
            for (delay, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
            }
        }

        private static func placeWindow() {
            guard let screen = NSScreen.main else { return }
            let frame = NSRect(x: screen.frame.maxX - 1440, y: screen.frame.maxY - 900 - 25, width: 1440, height: 900)
            NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.setFrame(frame, display: true, animate: false)
            NSApp.activate(ignoringOtherApps: true)
        }

        private static func reminder(_ title: String) -> Reminder? {
            AppModel.shared.open.first { $0.title.hasPrefix(title) }
        }

        private static func select(_ title: String) {
            guard let reminder = reminder(title) else { return }
            AppModel.shared.selection = reminder.id
        }

        /// Types like a person: one character every 60 ms, title first, then the date.
        private static func type(title: String, when: String) {
            let model = AppModel.shared
            for index in title.indices.map({ title.distance(from: title.startIndex, to: $0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(index)) {
                    model.demoTyping = (String(title.prefix(index + 1)), "")
                }
            }
            let start = 0.06 * Double(title.count) + 0.4
            for index in when.indices.map({ when.distance(from: when.startIndex, to: $0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.08 * Double(index)) {
                    model.demoTyping = (title, String(when.prefix(index + 1)))
                }
            }
        }

        private static func finishQuickAdd() {
            let model = AppModel.shared
            if let typed = model.demoTyping, let due = DateParser(preferred: "en").parse(typed.when) {
                model.add(title: typed.title, notes: "PR https://github.com/acme/ingress/pull/87", dueAt: due)
            }
            model.showQuickAdd = false
            model.demoTyping = nil
        }

        private static func notify(_ title: String) {
            guard let reminder = reminder(title) else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.subtitle = [Format.time(Date()), reminder.project].compactMap(\.self).joined(separator: " · ")
            content.body = Format.preview(reminder.notes)
            content.categoryIdentifier = NotificationCategory.ticket.rawValue
            content.userInfo = ["reminderId": reminder.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "demo-\(reminder.id)", content: content, trigger: nil))
        }

        private static func reschedule(_ title: String) {
            guard let reminder = reminder(title) else { return }
            AppModel.shared.selection = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AppModel.shared.focusDateField = true
                AppModel.shared.reveal(reminder.id)
            }
        }

        private static func seedLiveStatus() {
            let store = AppModel.shared.liveStatus
            let mergeRequest =
                #"{"iid":214,"title":"feat(scaler): roll out to all regions","state":"opened","draft":false,"detailed_merge_stat"# +
                #"us":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"web_url":"https://gitlab.com/acme/"# +
                #"platform/scaler/-/merge_requests/214","author":{"username":"alice"},"head_pipeline":{"status":"success","web_u"# +
                #"rl":"https://gitlab.com/acme/platform/scaler/-/pipelines/1"},"user":{"can_merge":true}}"#
            let approvals =
                #"{"approvals_required":1,"approvals_left":0,"user_has_approved":true,"user_can_approve":true,"approved_by":[{"u"# +
                #"ser":{"username":"bob"}}]}"#
            let ticket =
                #"{"key":"OPS-1042","fields":{"summary":"Roll the scaler out to every region","status":{"name":"In Progress","st"# +
                #"atusCategory":{"key":"indeterminate"}},"assignee":{"displayName":"You"}}}"#
            if let mr = try? LiveStatusParser.mergeRequest(mr: Data(mergeRequest.utf8), approvals: Data(approvals.utf8)) {
                store.setDemoStatus(.mergeRequest(mr), for: "https://gitlab.com/acme/platform/scaler/-/merge_requests/214")
            }
            if let issue = try? LiveStatusParser.ticket(Data(ticket.utf8)) {
                store.setDemoStatus(.ticket(issue), for: "https://acme.atlassian.net/browse/OPS-1042")
            }
        }
    }
#endif
