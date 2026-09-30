import SwiftUI
import TicklerCore

/// First launch: grant what Tickler needs, once, in one place. Every step can be skipped and redone from Settings.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var tools: [ExternalTool: String] = [:]
    @State private var checkedTools = false
    @State private var installing = false
    @State private var installOutput: String?
    @State private var confirmInstall = false

    var body: some View {
        @Bindable var preferences = model.preferences
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Tickler").font(.system(size: 20, weight: .bold))
                Text("Four quick steps. You can change all of it later in Settings.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "Notifications", done: model.notifications.authorized) { notificationsStep }
                    step(2, "Calendar", done: model.calendarSync.hasAccess && preferences.calendarId != nil) { calendarStep }
                    step(3, "Terminal", done: true) { terminalStep }
                    step(4, "Live status tools", done: checkedTools && toInstall.isEmpty) { toolsStep }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    preferences.onboardingDone = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 640)
        .background(Theme.listBackground)
        .task { await checkTools() }
        .confirmationDialog("Install with Homebrew?", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Install") { install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tickler will run: brew \(ToolCheck.installArguments(for: toInstall).joined(separator: " "))")
        }
    }

    // MARK: Steps

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A notification at the due time, with Resume, Snooze and Done on it.")
            if model.notifications.authorized {
                Text("Choose the Alerts style so reminders stay on screen until you act.").foregroundStyle(.secondary)
                Button("Open Notification Settings") { openSystemSettings("com.apple.Notifications-Settings.extension") }
            } else {
                Button(model.notifications.status == .denied ? "Open System Settings" : "Allow Notifications") {
                    Task { await model.notifications.requestOrOpenSettings() }
                }
                .buttonStyle(PrimaryButtonStyle())
                if model.notifications.status == .denied {
                    Text("Notifications were turned off for Tickler: switch them on in System Settings, then come back.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarStep: some View {
        @Bindable var preferences = model.preferences
        VStack(alignment: .leading, spacing: 8) {
            Text("Each reminder also appears as a 15 minute event, marked Free, in a calendar you pick.")
            if model.calendarSync.hasAccess {
                Picker("Calendar", selection: Binding(
                    get: { preferences.calendarId ?? "" },
                    set: { value in
                        preferences.calendarId = value.isEmpty ? nil : value
                        model.requestReconcile()
                    }
                )) {
                    Text("None").tag("")
                    ForEach(model.calendarSync.calendars, id: \.calendarIdentifier) { calendar in
                        Text("\(calendar.title) (\(calendar.source.title))").tag(calendar.calendarIdentifier)
                    }
                }
                .frame(maxWidth: 360)
                Text("Tip: create a \"Claude\" calendar in Google Calendar with default notifications set to none.")
                    .foregroundStyle(.secondary)
            } else {
                Button(model.calendarSync.isRefused ? "Open System Settings" : "Allow Calendar Access") {
                    Task { await model.calendarSync.requestOrOpenSettings() }
                }
                .buttonStyle(PrimaryButtonStyle())
                if model.calendarSync.isRefused {
                    Text("Give Tickler full access in System Settings > Privacy & Security > Calendars, then come back.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var terminalStep: some View {
        @Bindable var preferences = model.preferences
        return VStack(alignment: .leading, spacing: 8) {
            Text("Resume reopens the Claude session of a reminder. New tabs open in:")
            Picker("Terminal", selection: $preferences.terminal) {
                ForEach(TerminalChoice.available(weztermPath: preferences.weztermPath), id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var toolsStep: some View {
        @Bindable var preferences = model.preferences
        return VStack(alignment: .leading, spacing: 8) {
            Text("Shows pipelines, approvals and ticket status next to reminders. Pick the tools you use.")
            if !checkedTools {
                ProgressView().controlSize(.small)
            } else {
                ForEach(ExternalTool.allCases, id: \.self) { tool in
                    Toggle(isOn: Binding(
                        get: { preferences.enabledTools.contains(tool) },
                        set: { enabled in
                            if enabled {
                                preferences.enabledTools.insert(tool)
                            } else {
                                preferences.enabledTools.remove(tool)
                            }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Text(verbatim: tool.rawValue).font(.system(size: 13, design: .monospaced))
                            Text(tool.purpose).foregroundStyle(.secondary)
                            Spacer()
                            if let path = tools[tool] {
                                Label(path, systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
                                    .lineLimit(1)
                            } else {
                                Text("not installed").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if !toInstall.isEmpty {
                    if ToolCheck.homebrew() != nil {
                        HStack {
                            Button(installing ? "Installing…" : "Install with Homebrew") { confirmInstall = true }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(installing)
                            if installing {
                                ProgressView().controlSize(.small)
                            }
                        }
                    } else {
                        Text("Homebrew is not installed: install the missing tools yourself.").foregroundStyle(.secondary)
                    }
                }
                if let installOutput {
                    Text(installOutput).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !preferences.enabledTools.isEmpty {
                    Text("Then log in once in a terminal:").foregroundStyle(.secondary)
                    Text(verbatim: ExternalTool.allCases.filter { preferences.enabledTools.contains($0) }.map(\.loginCommand)
                        .joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: Helpers

    /// Enabled but not found: what the Homebrew button installs, nothing else.
    private var toInstall: [ExternalTool] {
        ExternalTool.allCases.filter { tools[$0] == nil && model.preferences.enabledTools.contains($0) }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.2) : Theme.accent.opacity(0.2)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text(verbatim: "\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content().font(.system(size: 12))
            }
        }
    }

    private func checkTools() async {
        var found: [ExternalTool: String] = [:]
        for tool in ExternalTool.allCases {
            if let path = await ToolCheck.locate(tool) {
                found[tool] = path
            }
        }
        tools = found
        // First setup: start from what is already installed.
        if !checkedTools, !model.preferences.onboardingDone, UserDefaults.standard.object(forKey: "enabledTools") == nil {
            model.preferences.enabledTools = Set(found.keys)
        }
        checkedTools = true
    }

    private func install() {
        guard let brew = ToolCheck.homebrew() else { return }
        let targets = toInstall
        installing = true
        installOutput = nil
        Task {
            do {
                installOutput = try await ToolCheck.install(targets, brew: brew)
            } catch {
                installOutput = String(describing: error)
            }
            installing = false
            await checkTools()
        }
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension ExternalTool {
    var purpose: String {
        switch self {
        case .glab: String(localized: "GitLab merge requests")
        case .jira: String(localized: "Jira issues")
        case .gh: String(localized: "GitHub pull requests")
        }
    }
}

extension TerminalChoice {
    var displayName: String {
        switch self {
        case .auto: String(localized: "Automatic (the first one running)")
        case .wezterm: "WezTerm"
        case .ghostty: "Ghostty"
        case .iterm: "iTerm2"
        }
    }
}
