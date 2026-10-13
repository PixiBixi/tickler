import AppKit
import SwiftUI
import TicklerCore

/// The pill under the notch showing the next reminder due within the lead time.
@MainActor
final class IslandController {
    private static let width: CGFloat = 360
    private static let rowHeight: CGFloat = 32

    private var panel: NSPanel?
    private var timer: Timer?
    /// Reminders clicked away, keyed by due date so a reschedule shows them again; kept in memory only.
    private var dismissed: Set<String> = []

    func start() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppModel.shared.island.update() }
        }
        update()
    }

    /// Plans from the model's open reminders; called after every reload and preference change.
    func update() {
        timer?.invalidate()
        timer = nil
        let model = AppModel.shared
        guard model.preferences.islandEnabled else {
            hide()
            return
        }
        let plan = IslandPlanner.plan(
            open: model.open.filter { !dismissed.contains(Self.key($0)) }, now: Date(),
            lead: TimeInterval(model.preferences.islandLeadMinutes * 60)
        )
        if let next = plan.nextChange {
            let timer = Timer(fire: next, interval: 0, repeats: false) { _ in
                Task { @MainActor in AppModel.shared.island.update() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if let reminder = plan.shown {
            show(reminder, others: plan.othersInWindow)
        } else {
            hide()
        }
    }

    private func show(_ reminder: Reminder, others: Int) {
        guard let screen = NSScreen.main else { return }
        let notch = screen.safeAreaInsets.top
        let model = AppModel.shared
        let reviewLink = (model.links[reminder.id] ?? [])
            .sorted { $0.position < $1.position }
            .first { $0.kind == .gitlabMR || $0.kind == .githubPR }
        let view = IslandView(
            reminder: reminder, others: others, topInset: notch, rowHeight: Self.rowHeight,
            reviewLink: reviewLink, canResume: reminder.sessionId != nil
        ) { action in
            AppModel.shared.island.dismiss(reminder)
            switch action {
            case .reveal: AppModel.shared.reveal(reminder.id)
            case let .openLink(link): AppModel.shared.open(link)
            case .resume: AppModel.shared.resume(reminder)
            }
        }
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: view)
        let height = notch + Self.rowHeight
        // With a notch the pill starts at the screen top and reads as its extension; without, it sits under the menu bar.
        let top = notch > 0 ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        panel.setFrame(NSRect(x: screen.frame.midX - Self.width / 2, y: top - height, width: Self.width, height: height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func dismiss(_ reminder: Reminder) {
        dismissed.insert(Self.key(reminder))
        update()
    }

    private static func key(_ reminder: Reminder) -> String {
        "\(reminder.id)@\(Int(reminder.dueAt.timeIntervalSince1970))"
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = .statusBar
        // No .fullScreenAuxiliary: the pill stays off a full screen app's space.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}
