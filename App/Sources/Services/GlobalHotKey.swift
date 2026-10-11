import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier flags, as `RegisterEventHotKey` takes them.
struct HotKeyShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// What the key shows, captured when recorded: the key code alone depends on the keyboard layout.
    var key: String

    static let standard = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey), key: "N")

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Nil without ⌘, ⌥ or ⌃: a global shortcut on a bare or shifted key would swallow typing in every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let code = Int(event.keyCode)
        guard let key = Self.specialKeys[code] ?? event.charactersIgnoringModifiers?.uppercased(),
              !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        var modifiers = 0
        if flags.contains(.command) {
            modifiers |= cmdKey
        }
        if flags.contains(.option) {
            modifiers |= optionKey
        }
        if flags.contains(.control) {
            modifiers |= controlKey
        }
        if flags.contains(.shift) {
            modifiers |= shiftKey
        }
        self.init(keyCode: UInt32(code), modifiers: UInt32(modifiers), key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// In the order macOS menus print them: ⌃⌥⇧⌘.
    var display: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }
}

/// The shortcut from any app opens the new reminder sheet. Carbon's hot key API needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// False when another app already holds the shortcut.
    @discardableResult
    func setEnabled(_ enabled: Bool, shortcut: HotKeyShortcut) -> Bool {
        unregister()
        return enabled ? register(shortcut) : true
    }

    private func register(_ shortcut: HotKeyShortcut) -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.quickAddFromAnywhere() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        // "TKLR": the signature only has to be unique to this app.
        let identifier = EventHotKeyID(signature: OSType(0x544B_4C52), id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            unregister()
            return false
        }
        return true
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
