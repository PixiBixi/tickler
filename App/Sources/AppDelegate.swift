import AppKit
import TicklerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            // Opened by the user: show the window. Started at login: stay in the menu bar.
            if !Self.launchedAtLogin() {
                AppModel.shared.showMainWindow()
            }
            #if DEBUG
                DebugSnapshot.scheduleIfRequested()
                DemoDriver.startIfRequested()
            #endif
        }
    }

    private static func launchedAtLogin() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// `tickler://open/<id>` from calendar events, `tickler://view/<filter>` from the session start hook.
    func application(_: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme == Tickler.urlScheme {
                AppModel.shared.open(url)
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the window: the menu bar icon can be hidden by the notch.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        MainActor.assumeIsolated {
            AppModel.shared.showMainWindow()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
