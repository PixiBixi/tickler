import SwiftUI
import TicklerCore

/// Settings in tabs, each as tall as its content.
struct SettingsView: View {
    enum Tab: String {
        case general, calendar, sessions, live, claude
    }

    @State private var tab = Self.initialTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            CalendarSettings()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            SessionSettings()
                .tabItem { Label("Sessions", systemImage: "terminal") }
                .tag(Tab.sessions)
            LiveStatusSettings()
                .tabItem { Label("Live Status", systemImage: "waveform.path.ecg") }
                .tag(Tab.live)
            ClaudeCodeSettings()
                .tabItem { Label("Claude Code", systemImage: "sparkle") }
                .tag(Tab.claude)
        }
        .frame(width: 560)
    }

    private static var initialTab: Tab {
        #if DEBUG
            ProcessInfo.processInfo.environment["TICKLER_SETTINGS"].flatMap(Tab.init(rawValue:)) ?? .general
        #else
            .general
        #endif
    }
}

/// One tab: a grouped form as tall as its content, so the window resizes per tab instead of scrolling.
private struct SettingsTab<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var languageChanged = false

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsTab {
            Section {
                Picker("Language", selection: Binding(
                    get: { preferences.language },
                    set: { preferences.language = $0; languageChanged = true }
                )) {
                    Text("System").tag(Preferences.Language.system)
                    Text(verbatim: "English").tag(Preferences.Language.en)
                    Text(verbatim: "Français").tag(Preferences.Language.fr)
                }
                if languageChanged {
                    HStack {
                        Text("Takes effect after a relaunch.").font(.caption).foregroundStyle(.secondary)
                        Button("Relaunch Now", action: relaunch).buttonStyle(SecondaryButtonStyle())
                    }
                }
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { preferences.launchAtLogin = $0; launchAtLogin = preferences.launchAtLogin }
                ))
            }
            Section("New Reminder") {
                Toggle("New reminder from anywhere", isOn: $preferences.globalShortcut)
                if preferences.globalShortcut {
                    LabeledContent("Shortcut") { ShortcutRecorder(preferences: preferences) }
                }
                Toggle("Notify when a reminder is added from outside the app", isOn: $preferences.announceNewReminders)
            }
            Section("Notch") {
                Toggle("Show the next reminder near the notch", isOn: $preferences.islandEnabled)
                if preferences.islandEnabled {
                    LabeledContent("Show it before the reminder") {
                        HStack(spacing: 6) {
                            TextField("", value: $preferences.islandLeadMinutes, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Text("min").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                LabeledContent {
                    Button("Open Assistant…") {
                        model.showOnboarding = true
                        model.showMainWindow()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } label: {
                    Text("Setup assistant")
                    Text("Permissions, terminal and live status tools, as on first launch.")
                }
                LabeledContent("Version") { Text(verbatim: Tickler.version).textSelection(.enabled) }
            }
        }
        .onAppear { launchAtLogin = preferences.launchAtLogin }
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

private struct CalendarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsTab {
            Section {
                if model.calendarSync.hasAccess {
                    Picker("Copy reminders to", selection: Binding(
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
                    (Text("Events are marked Free and have no alert.")
                        + Text(" ")
                        + Text("In Google Calendar, set this calendar's default notifications to none to avoid double alerts."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(model.calendarSync.isRefused ? "Allow in System Settings" : "Allow Calendar Access") {
                        Task { await model.calendarSync.requestOrOpenSettings() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    if model.calendarSync.isRefused {
                        Text("Access was refused, and macOS only asks once: switch Tickler on in Privacy & Security > Calendars.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Tickler only writes to the calendar you pick.").font(.caption).foregroundStyle(.secondary)
                }
                CalendarStatusLabel()
            }
        }
        .onAppear { model.calendarSync.loadCalendars() }
    }
}

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsTab {
            Section {
                Picker("Terminal", selection: $preferences.terminal) {
                    // Only what is installed, plus the current choice so a removed app does not blank the picker.
                    ForEach(terminalChoices(current: preferences.terminal), id: \.self) { choice in
                        switch choice {
                        case .auto: Text("Automatic").tag(choice)
                        case .wezterm: Text(verbatim: "WezTerm").tag(choice)
                        case .ghostty: Text(verbatim: "Ghostty").tag(choice)
                        case .iterm: Text(verbatim: "iTerm2").tag(choice)
                        }
                    }
                }
                Text(
                    "Running sessions are found in any terminal; new tabs open in this one. Automatic uses the first one running."
                )
                .font(.caption).foregroundStyle(.secondary)
                // Only WezTerm is driven through its binary; Ghostty and iTerm2 go through AppleScript.
                if preferences.terminal == .wezterm || preferences.terminal == .auto {
                    TextField(
                        "WezTerm binary",
                        text: $preferences.weztermPath,
                        prompt: Text(WezTermDriver.resolveBinary()?.path ?? "/opt/homebrew/bin/wezterm")
                    )
                    Text("Leave empty to use the one found automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func terminalChoices(current: TerminalChoice) -> [TerminalChoice] {
        let available = TerminalChoice.available(weztermPath: model.preferences.weztermPath)
        return available.contains(current) ? available : available + [current]
    }
}

private struct LiveStatusSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsTab {
            Section {
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
                        Text(verbatim: tool.rawValue).font(.system(.body, design: .monospaced)) + Text(verbatim: "  ") + Text(tool.purpose)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if preferences.enabledTools.contains(.jira) {
                Section {
                    JiraTokenRow()
                }
            }
        }
    }
}

private struct ClaudeCodeSettings: View {
    var body: some View {
        SettingsTab {
            Section {
                SkillInstallRow(title: "Claude Code Skill")
                HookInstallRow(title: "Session Start Hook")
            } footer: {
                Text(
                    "The skill teaches Claude when to create a reminder; the hook lists the repository's reminders when a session starts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
