import Foundation
import ServiceManagement
import TicklerCore

/// User settings, stored in the app's defaults.
@MainActor
@Observable
final class Preferences {
    enum Language: String, CaseIterable, Identifiable {
        case system
        case en
        case fr

        var id: String {
            rawValue
        }
    }

    private let defaults = UserDefaults.standard

    var calendarId: String? {
        didSet { defaults.set(calendarId, forKey: "calendarId") }
    }

    var weztermPath: String {
        didSet { defaults.set(weztermPath, forKey: "weztermPath") }
    }

    /// Which CLIs live status may call. Never set: all of them, so an upgrade keeps working.
    var enabledTools: Set<ExternalTool> {
        didSet { defaults.set(enabledTools.map(\.rawValue).sorted(), forKey: "enabledTools") }
    }

    var globalShortcut: Bool {
        didSet {
            defaults.set(globalShortcut, forKey: "globalShortcut")
            GlobalHotKey.shared.setEnabled(globalShortcut, shortcut: shortcut)
        }
    }

    /// Change it through `changeShortcut`, which keeps the old one when the new one is taken.
    private(set) var shortcut: HotKeyShortcut {
        didSet {
            defaults.set(Int(shortcut.keyCode), forKey: "shortcutKeyCode")
            defaults.set(Int(shortcut.modifiers), forKey: "shortcutModifiers")
            defaults.set(shortcut.key, forKey: "shortcutKey")
        }
    }

    var announceNewReminders: Bool {
        didSet { defaults.set(announceNewReminders, forKey: "announceNewReminders") }
    }

    /// The pill under the notch showing the next reminder.
    var islandEnabled: Bool {
        didSet {
            defaults.set(islandEnabled, forKey: "islandEnabled")
            AppModel.shared.island.update()
        }
    }

    /// How long before its due date a reminder shows under the notch.
    var islandLeadMinutes: Int {
        didSet {
            // @Observable routes this write back through didSet: assign only when out of range, or it recurses forever.
            let clamped = min(max(islandLeadMinutes, 1), 120)
            guard clamped == islandLeadMinutes else {
                islandLeadMinutes = clamped
                return
            }
            defaults.set(islandLeadMinutes, forKey: "islandLeadMinutes")
            AppModel.shared.island.update()
        }
    }

    var bannerHintDismissed: Bool {
        didSet { defaults.set(bannerHintDismissed, forKey: "bannerHintDismissed") }
    }

    var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: "onboardingDone") }
    }

    var terminal: TerminalChoice {
        didSet { defaults.set(terminal.rawValue, forKey: "terminal") }
    }

    var language: Language {
        didSet { applyLanguage() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                AppModel.shared.showError(String(localized: "Could not change the login item: \(error.localizedDescription)"))
            }
        }
    }

    init() {
        calendarId = defaults.string(forKey: "calendarId")
        weztermPath = defaults.string(forKey: "weztermPath") ?? ""
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        bannerHintDismissed = defaults.bool(forKey: "bannerHintDismissed")
        announceNewReminders = defaults.object(forKey: "announceNewReminders") as? Bool ?? true
        globalShortcut = defaults.object(forKey: "globalShortcut") as? Bool ?? true
        islandEnabled = defaults.object(forKey: "islandEnabled") as? Bool ?? false
        islandLeadMinutes = defaults.object(forKey: "islandLeadMinutes") as? Int ?? 5
        if let keyCode = defaults.object(forKey: "shortcutKeyCode") as? Int,
           let modifiers = defaults.object(forKey: "shortcutModifiers") as? Int,
           let key = defaults.string(forKey: "shortcutKey")
        {
            shortcut = HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), key: key)
        } else {
            shortcut = .standard
        }
        enabledTools = defaults.stringArray(forKey: "enabledTools")
            .map { Set($0.compactMap(ExternalTool.init(rawValue:))) } ?? Set(ExternalTool.allCases)
        terminal = TerminalChoice(rawValue: defaults.string(forKey: "terminal") ?? "") ?? .auto
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
    }

    /// False when another app holds the new shortcut: the old one stays registered.
    func changeShortcut(_ new: HotKeyShortcut) -> Bool {
        guard GlobalHotKey.shared.setEnabled(globalShortcut, shortcut: new) else {
            GlobalHotKey.shared.setEnabled(globalShortcut, shortcut: shortcut)
            return false
        }
        shortcut = new
        return true
    }

    /// Takes effect at the next launch: AppKit reads AppleLanguages once.
    private func applyLanguage() {
        defaults.set(language.rawValue, forKey: "language")
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}
