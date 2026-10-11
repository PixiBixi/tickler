import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then type the new global shortcut; Esc cancels.
struct ShortcutRecorder: View {
    let preferences: Preferences
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button {
                    recording ? stop() : start()
                } label: {
                    Group {
                        if recording {
                            Text("Type the shortcut…")
                        } else {
                            Text(verbatim: preferences.shortcut.display)
                        }
                    }
                    .frame(minWidth: 110)
                }
                .buttonStyle(SecondaryButtonStyle())
                if preferences.shortcut != .standard, !recording {
                    Button("Reset") { record(.standard) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        recording = true
        // Unregistered while recording, or typing the current shortcut would open the sheet.
        GlobalHotKey.shared.setEnabled(false, shortcut: preferences.shortcut)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let shortcut = HotKeyShortcut(event: event) {
                record(shortcut)
            } else {
                message = "Use at least ⌘, ⌥ or ⌃."
            }
            return nil
        }
    }

    private func record(_ shortcut: HotKeyShortcut) {
        removeMonitor()
        if preferences.changeShortcut(shortcut) {
            message = nil
        } else {
            message = "Another app already uses this shortcut."
        }
    }

    private func stop() {
        guard recording else { return }
        removeMonitor()
        GlobalHotKey.shared.setEnabled(preferences.globalShortcut, shortcut: preferences.shortcut)
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
    }
}
