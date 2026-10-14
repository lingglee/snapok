import Foundation

/// What the user picked in Settings → General → Language. A fresh installation follows the system.
enum LanguagePreference: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static func saved(in defaults: UserDefaults = .standard) -> LanguagePreference {
        LanguagePreference(rawValue: defaults.string(forKey: AppLanguage.preferenceKey) ?? "") ?? .system
    }

    /// The language the app runs in for this choice; `systemLanguages` is macOS's list, most preferred first.
    func resolved(systemLanguages: [String] = AppLanguage.systemLanguages()) -> AppLanguage {
        switch self {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .system:
            // The first language the app speaks wins; Chinese in any script reads Simplified Chinese best.
            for identifier in systemLanguages {
                let code = identifier.lowercased()
                if code.hasPrefix("zh") { return .simplifiedChinese }
                if code.hasPrefix("en") { return .english }
            }
            return .english
        }
    }
}

/// The language the app is running in, resolved from `LanguagePreference`.
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "app.language"

    static func saved(in defaults: UserDefaults = .standard, systemLanguages: [String]? = nil) -> AppLanguage {
        LanguagePreference.saved(in: defaults).resolved(systemLanguages: systemLanguages ?? Self.systemLanguages())
    }

    /// macOS's own language order (System Settings → General → Language & Region), not this app's override.
    static func systemLanguages() -> [String] {
        CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
    }

    static let didChange = Notification.Name("AppLanguage.didChange")

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // Let AppKit's standard dialogs use the same language on the next launch.
        defaults.set([rawValue], forKey: "AppleLanguages")
    }

    // Read once at launch; afterwards only `switchTo` changes it, so stray preference writes never
    // half-translate the UI. Written on the main thread only.
    nonisolated(unsafe) private static var active = saved()

    static var current: AppLanguage { active }

    /// Saves the choice and switches the running app; observers of `didChange` rebuild their text.
    static func switchTo(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        language.save(in: defaults)
        activate(language)
    }

    /// Saves a preference, including following the system, and switches the running app to what it resolves to.
    static func switchTo(_ preference: LanguagePreference, in defaults: UserDefaults = .standard) {
        switch preference {
        case .system:
            defaults.set(LanguagePreference.system.rawValue, forKey: preferenceKey)
            // AppKit's standard dialogs follow the system again from the next launch.
            defaults.removeObject(forKey: "AppleLanguages")
            activate(preference.resolved())
        case .english: switchTo(AppLanguage.english, in: defaults)
        case .simplifiedChinese: switchTo(AppLanguage.simplifiedChinese, in: defaults)
        }
    }

    private static func activate(_ language: AppLanguage) {
        guard language != active else { return }
        active = language
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    var locale: Locale { Locale(identifier: rawValue) }

    func text(_ english: String, _ chinese: String) -> String {
        self == .simplifiedChinese ? chinese : english
    }
}

func L(_ english: String, _ chinese: String) -> String {
    AppLanguage.current.text(english, chinese)
}
