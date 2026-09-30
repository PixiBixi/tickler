import Foundation

/// Cross-process "the database changed" signal, over the Darwin notify center.
public enum ChangeNotifier {
    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Tickler.changedNotification as CFString),
            nil, nil, true
        )
    }
}

/// Calls `handler` on every `ChangeNotifier.post()`, from any process, until deallocated.
public final class ChangeObserver: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    public init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ChangeObserver>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            Tickler.changedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
