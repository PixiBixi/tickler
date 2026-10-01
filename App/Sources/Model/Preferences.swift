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
            GlobalHotKey.shared.setEnabled(globalShortcut)
        }
    }

    var announceNewReminders: Bool {
        didSet { defaults.set(announceNewReminders, forKey: "announceNewReminders") }
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
        announceNewReminders = defaults.object(forKey: "announceNewReminders") as? Bool ?? true
        globalShortcut = defaults.object(forKey: "globalShortcut") as? Bool ?? true
        enabledTools = defaults.stringArray(forKey: "enabledTools")
            .map { Set($0.compactMap(ExternalTool.init(rawValue:))) } ?? Set(ExternalTool.allCases)
        terminal = TerminalChoice(rawValue: defaults.string(forKey: "terminal") ?? "") ?? .auto
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
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
