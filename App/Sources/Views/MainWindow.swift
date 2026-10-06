import SwiftUI
import TicklerCore

/// Three fixed columns as in the design: a flush sidebar, the list, the detail. No NavigationSplitView:
/// on macOS 26 it draws a floating glass sidebar the design does not have.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 232)
            Divider()
            ReminderListView()
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 560)
            Divider()
            Group {
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
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.detailBackground)
        }
        .background(Theme.listBackground)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { ToastOverlay(toast: model.toast) }
        .sheet(isPresented: $model.showQuickAdd) { QuickAddSheet() }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView() }
        .onAppear {
            model.openMainWindow = {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if !model.preferences.onboardingDone {
                model.showOnboarding = true
            }
        }
        .onDisappear {
            // Back to a menu bar only app once the window is closed.
            NSApp.setActivationPolicy(.accessory)
        }
        .onOpenURL { url in
            model.open(url)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    sectionTitle("Views")
                    row(.today, "Today")
                    row(.week, "Next 7 Days")
                    row(.overdue, "Overdue", countColor: Theme.overdue)
                    row(.all, "All")
                    row(.done, "Done")
                    if !model.projects.isEmpty {
                        sectionTitle("Projects").padding(.top, 14)
                        ForEach(model.projects, id: \.name) { project in
                            row(.project(project.name), LocalizedStringKey(project.name), monospaced: true, verbatim: project.name)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if model.notifications.usesBanners, !model.preferences.bannerHintDismissed {
                    AlertsHint()
                }
                HStack {
                    SettingsLink { CalendarStatusLabel() }
                        .buttonStyle(.plain)
                        .help("Calendar settings")
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Settings (⌘,)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(Theme.sidebarBackground)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }

    private func row(
        _ filter: SidebarFilter,
        _ title: LocalizedStringKey,
        countColor: Color = .secondary,
        monospaced: Bool = false,
        verbatim: String? = nil
    ) -> some View {
        let count = model.count(for: filter)
        let selected = model.filter == filter
        return Button {
            model.filter = filter
        } label: {
            HStack {
                Group {
                    if let verbatim {
                        Text(verbatim)
                    } else {
                        Text(title)
                    }
                }
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.primary.opacity(0.8) : countColor)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Banner-style notifications vanish after a few seconds: one click to the Tickler pane of System Settings.
private struct AlertsHint: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.badge").font(.system(size: 12)).foregroundStyle(.orange)
            Button {
                let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Tickler.bundleIdentifier)"
                if let url = URL(string: pane) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reminders vanish after a few seconds").foregroundStyle(.primary)
                    Text("Switch to Persistent alerts ›").foregroundStyle(.orange).underline(hovering)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            Button { model.preferences.bannerHintDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide")
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
