import Foundation
import TicklerCore

/// Fires the triggers of waiting reminders. Runs only while the app does: the deadline covers the rest.
@MainActor
final class TriggerWatcher {
    static let interval: TimeInterval = 300

    private var timer: Timer?
    private var checking = false
    private var pending = false
    private var lastFailure: String?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.triggerWatcher.check() }
        }
        check()
    }

    /// One check at a time: a slow glab must not stack fetches of the same links. A call during a run reruns it once after.
    func check() {
        let model = AppModel.shared
        guard !model.isDemo, let store = model.store else { return }
        if checking {
            pending = true
            return
        }
        let waiting = model.open.filter(\.isWaiting)
        guard !waiting.isEmpty else { return }
        checking = true
        Task {
            let statuses = await model.liveStatus.fetchNow(waiting.flatMap { model.links(of: $0) })
            let checked = Set(waiting.map(\.id))
            var fired = false
            var failure: String?
            // The current reminders, not the snapshot: a trigger edited or cleared during the fetch must not fire.
            for reminder in model.open where reminder.isWaiting && checked.contains(reminder.id) {
                guard let trigger = reminder.parsedTrigger,
                      case let .fired(reason) = TriggerEvaluator.evaluate(trigger, links: model.links(of: reminder), statuses: statuses)
                else { continue }
                do {
                    fired = try store.fire(reminder.id, reason: reason, at: Date()) || fired
                } catch {
                    failure = String(describing: error)
                }
            }
            checking = false
            report(failure)
            if fired {
                model.reload()
                // A fired reminder is overdue and not yet notified: the catch-up path notifies it now.
                model.requestReconcile(catchUp: true)
            }
            if pending {
                pending = false
                check()
            }
        }
    }

    /// A failed write shows once, not at every check, until a check goes through without one.
    private func report(_ failure: String?) {
        if let failure, failure != lastFailure {
            AppModel.shared.showError(failure)
        }
        lastFailure = failure
    }
}
