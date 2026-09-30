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
