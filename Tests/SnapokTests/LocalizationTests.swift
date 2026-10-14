import Foundation

@main
struct LocalizationTests {
    static func main() {
        let suite = "Snapok.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A fresh installation follows the system: the first of English or Chinese in macOS's order, else English.
        precondition(LanguagePreference.saved(in: defaults) == .system)
        precondition(AppLanguage.saved(in: defaults, systemLanguages: ["en-US", "zh-Hans-CN"]) == .english)
        precondition(AppLanguage.saved(in: defaults, systemLanguages: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        precondition(AppLanguage.saved(in: defaults, systemLanguages: ["ja-JP", "zh-Hant-TW"]) == .simplifiedChinese)
        precondition(AppLanguage.saved(in: defaults, systemLanguages: ["fr-FR"]) == .english)
        defaults.set("invalid-language", forKey: AppLanguage.preferenceKey)
        precondition(LanguagePreference.saved(in: defaults) == .system, "Unknown values follow the system")
        // An explicit choice wins over the system.
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        precondition(AppLanguage.saved(in: defaults, systemLanguages: ["zh-Hans-CN"]) == .english)
        defaults.set("system", forKey: AppLanguage.preferenceKey)
        precondition(AppLanguage.saved(in: defaults, systemLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
        for language in AppLanguage.allCases {
            language.save(in: defaults)
            precondition(AppLanguage.saved(in: UserDefaults(suiteName: suite)!, systemLanguages: ["fr"]) == language)
            precondition(defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
        }
        // Use a process-local override, never touching the real app's preferences.
        let language = CommandLine.arguments.contains("--chinese") ? AppLanguage.simplifiedChinese : .english
        UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: language.rawValue], forName: UserDefaults.argumentDomain)
        precondition(AppLanguage.current == language)
        precondition(L("Settings", "设置") == (language == .english ? "Settings" : "设置"))
        precondition(L("Deleted \(3) screenshots", "删除 \(3) 张截图").contains("3"))
        // Switching explicitly updates the running app at once, notifies observers, and persists.
        let other: AppLanguage = language == .english ? .simplifiedChinese : .english
        nonisolated(unsafe) var notified = 0
        let observer = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: nil, queue: nil) { _ in notified += 1 }
        AppLanguage.switchTo(other, in: defaults)
        // The argument-domain override above shadows reads, so check the stored value directly.
        precondition(AppLanguage.current == other && notified == 1)
        precondition(defaults.persistentDomain(forName: suite)?[AppLanguage.preferenceKey] as? String == other.rawValue)
        precondition(L("Settings", "设置") == (other == .english ? "Settings" : "设置"))
        AppLanguage.switchTo(other, in: defaults)
        precondition(notified == 1, "re-selecting the current language must not rebuild the UI")
        AppLanguage.switchTo(language, in: defaults)
        precondition(AppLanguage.current == language && notified == 2)
        NotificationCenter.default.removeObserver(observer)
        // Changing the preference must not partially translate already-open windows.
        UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: "unsupported"], forName: UserDefaults.argumentDomain)
        precondition(AppLanguage.current == language)
        print("Passed localization checks (\(language.rawValue)): default, fallback, persistence, interpolation, session stability, live switching")
    }
}
