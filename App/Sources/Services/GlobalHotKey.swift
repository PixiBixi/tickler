import AppKit
import Carbon.HIToolbox

/// ⌥⌘N from any app opens the new reminder sheet. Carbon's hot key API needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.quickAddFromAnywhere() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        // "TKLR": the signature only has to be unique to this app.
        let identifier = EventHotKeyID(signature: OSType(0x544B_4C52), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        hotKey = nil
        handler = nil
    }
}
