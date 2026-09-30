import AppKit
import TicklerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            #if DEBUG
                DebugSnapshot.scheduleIfRequested()
            #endif
        }
    }

    /// `tickler://open/<id>`, from calendar events and the future web UI.
    func application(_: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme == Tickler.urlScheme {
                let parts = url.pathComponents.filter { $0 != "/" }
                if url.host() == "open", let id = parts.first {
                    AppModel.shared.reveal(id)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
