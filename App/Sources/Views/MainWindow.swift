import SwiftUI
import TicklerCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            ReminderListView()
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 560)
        } detail: {
            if let reminder = model.selectedReminder {
                ReminderDetailView(reminder: reminder)
                    .id(reminder.id)
            } else {
                ContentUnavailableView(
                    "No Reminder Selected",
                    systemImage: "checklist",
                    description: Text("Pick a reminder to see its notes and actions.")
                )
            }
        }
        .overlay(alignment: .bottom) { ToastOverlay(toast: model.toast) }
        .sheet(isPresented: $model.showQuickAdd) { QuickAddSheet() }
        .onAppear {
            model.openMainWindow = {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            // Back to a menu bar only app once the window is closed.
            NSApp.setActivationPolicy(.accessory)
        }
        .onOpenURL { url in
            let parts = url.pathComponents.filter { $0 != "/" }
            if url.host() == "open", let id = parts.first {
                model.reveal(id)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.filter) {
            Section("Views") {
                row(.today, "Today", "sun.max")
                row(.week, "Next 7 Days", "calendar")
                row(.overdue, "Overdue", "exclamationmark.circle")
                row(.all, "All", "tray.full")
                row(.done, "Done", "checkmark.circle")
            }
            if !model.projects.isEmpty {
                Section("Projects") {
                    ForEach(model.projects, id: \.name) { project in
                        Label {
                            HStack {
                                Text(project.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Text("\(project.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .tag(SidebarFilter.project(project.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if model.notifications.usesBanners {
                    Label(
                        "Set Tickler to Alerts in System Settings > Notifications, so reminders stay on screen.",
                        systemImage: "bell.badge"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }
                CalendarStatusLabel()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func row(_ filter: SidebarFilter, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        let count = model.count(for: filter)
        return Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(filter == .overdue ? Theme.overdue : .secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(filter)
    }
}
