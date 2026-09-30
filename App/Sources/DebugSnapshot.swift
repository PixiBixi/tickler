#if DEBUG
    import AppKit

    /// Debug builds only: `TICKLER_SNAPSHOT=<dir>` writes a PNG of every visible window, to check layouts without a screen.
    enum DebugSnapshot {
        @MainActor
        static func scheduleIfRequested() {
            guard let directory = ProcessInfo.processInfo.environment["TICKLER_SNAPSHOT"] else { return }
            if let id = ProcessInfo.processInfo.environment["TICKLER_SELECT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppModel.shared.reveal(id) }
            }
            // TICKLER_SNAPSHOT_SIZE=WxH resizes the windows first, to check wide layouts.
            if let size = ProcessInfo.processInfo.environment["TICKLER_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    for window in NSApp.windows.filter(\.isVisible) {
                        window.setFrame(
                            NSRect(x: 0, y: 0, width: size[0], height: size[1]),
                            display: true
                        )
                    }
                }
            }
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
