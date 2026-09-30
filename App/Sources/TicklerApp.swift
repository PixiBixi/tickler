import SwiftUI
import TicklerCore

@main
struct TicklerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Tickler", id: WindowID.main) {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Reminder") { model.showQuickAdd = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Reminder") {
                Button("Resume Session") { model.resumeSelected() }
                    .keyboardShortcut("r")
                    .disabled(model.selectedReminder?.sessionId == nil)
                Button("Mark Done") { model.markSelectedDone() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedReminder == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
}
