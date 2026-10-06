import Foundation
import TicklerCore

/// Fires the triggers of waiting reminders. Runs only while the app does: the deadline covers the rest.
@MainActor
final class TriggerWatcher {
    static let interval: TimeInterval = 300

    private var timer: Timer?
    private var checking = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.triggerWatcher.check() }
        }
        check()
    }

    /// One check at a time: a slow glab must not stack fetches of the same links.
    func check() {
        let model = AppModel.shared
        guard !checking, !model.isDemo, let store = model.store else { return }
        let waiting = model.open.filter(\.isWaiting)
        guard !waiting.isEmpty else { return }
        checking = true
        Task {
            let statuses = await model.liveStatus.fetchNow(waiting.flatMap { model.links(of: $0) })
            var fired = false
            for reminder in waiting {
                guard let trigger = reminder.parsedTrigger,
                      case let .fired(reason) = TriggerEvaluator.evaluate(trigger, links: model.links(of: reminder), statuses: statuses)
                else { continue }
                fired = (try? store.fire(reminder.id, reason: reason, at: Date())) == true || fired
            }
            checking = false
            if fired {
                model.reload()
                // A fired reminder is overdue and not yet notified: the catch-up path notifies it now.
                model.requestReconcile(catchUp: true)
            }
        }
    }
}
