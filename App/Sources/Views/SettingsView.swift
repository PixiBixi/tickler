import SwiftUI
import TicklerCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var languageChanged = false

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Calendar") {
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
                    Text("Events are marked Free and have no alert.")
                        + Text(" ")
                        + Text("In Google Calendar, set this calendar's default notifications to none to avoid double alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Allow Calendar Access") {
                        Task {
                            _ = await model.calendarSync.requestAccess()
                        }
                    }
                    Text("Tickler only writes to the calendar you pick.").font(.caption).foregroundStyle(.secondary)
                }
                CalendarStatusLabel()
            }

            Section("Resume") {
                Picker("Terminal", selection: $preferences.terminal) {
                    Text("Automatic").tag(TerminalChoice.auto)
                    Text(verbatim: "WezTerm").tag(TerminalChoice.wezterm)
                    Text(verbatim: "Ghostty").tag(TerminalChoice.ghostty)
                    Text(verbatim: "iTerm2").tag(TerminalChoice.iterm)
                }
                Text(
                    "Running sessions are found in any terminal; new tabs open in this one. Automatic uses the first one running."
                )
                .font(.caption).foregroundStyle(.secondary)
                TextField(
                    "WezTerm binary",
                    text: $preferences.weztermPath,
                    prompt: Text(WezTermDriver.resolveBinary()?.path ?? "/opt/homebrew/bin/wezterm")
                )
                Text("Leave empty to use the one found automatically.").font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
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
                        Button("Relaunch Now", action: relaunch)
                    }
                }
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { preferences.launchAtLogin = $0; launchAtLogin = preferences.launchAtLogin }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = preferences.launchAtLogin
            model.calendarSync.loadCalendars()
        }
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
