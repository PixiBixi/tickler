#if DEBUG
    import AppKit

    /// Debug builds only: `TICKLER_SNAPSHOT=<dir>` writes a PNG of every visible window, to check layouts without a screen.
    enum DebugSnapshot {
        @MainActor
        static func scheduleIfRequested() {
            guard let directory = ProcessInfo.processInfo.environment["TICKLER_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = window.title.isEmpty ? "window-\(index)" : window.title
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(index).png"))
                }
            }
        }
    }
#endif
