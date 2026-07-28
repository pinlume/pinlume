import Foundation

/// Manages the active language for the app.
/// Loads from UserDefaults ("appLanguage"), falls back to system language, then English.
/// The selected bundle is fixed for the process lifetime; changes apply after restart.
final class LanguageManager {
    static let shared = LanguageManager()

    /// Every bundled locale with a `Localizable.strings` file is selectable.
    /// System, Simplified Chinese and English are fixed first; the rest sort by
    /// their own language names so the Settings list stays easy to scan.
    static let availableLanguages: [(code: String, name: String)] = [
        ("system", "System Default"),
        ("zh-Hans", "简体中文"),
        ("en", "English"),
    ] + [
        ("ar", "العربية"),
        ("bg", "Български"),
        ("bn", "বাংলা"),
        ("ca", "Català"),
        ("cs", "Čeština"),
        ("da", "Dansk"),
        ("de", "Deutsch"),
        ("el", "Ελληνικά"),
        ("es", "Español"),
        ("fa", "فارسی"),
        ("fi", "Suomi"),
        ("fil", "Filipino"),
        ("fr", "Français"),
        ("he", "עברית"),
        ("hi", "हिन्दी"),
        ("hr", "Hrvatski"),
        ("hu", "Magyar"),
        ("id", "Bahasa Indonesia"),
        ("it", "Italiano"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("ms", "Bahasa Melayu"),
        ("nb", "Norsk bokmål"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("pt", "Português"),
        ("pt-BR", "Português (Brasil)"),
        ("ro", "Română"),
        ("ru", "Русский"),
        ("sk", "Slovenčina"),
        ("sr", "Српски"),
        ("sv", "Svenska"),
        ("ta", "தமிழ்"),
        ("th", "ไทย"),
        ("tr", "Türkçe"),
        ("uk", "Українська"),
        ("vi", "Tiếng Việt"),
        ("zh-Hant", "繁體中文"),
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static let supportedLanguageCodes = Set(availableLanguages.map(\.code))

    private var bundle: Bundle = .main

    private init() {
        reload()
    }

    /// The active language code. "system" means follow macOS preference.
    var currentLanguage: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
            return Self.canonicalSupportedCode(for: stored) ?? "en"
        }
        set {
            let value = Self.canonicalSupportedCode(for: newValue) ?? "en"
            UserDefaults.standard.set(value, forKey: "appLanguage")
        }
    }

    /// Resolves the actual language code (never "system").
    var resolvedLanguage: String {
        Self.resolve(selected: currentLanguage, preferredLanguages: Locale.preferredLanguages)
    }

    static func resolve(selected: String, preferredLanguages: [String]) -> String {
        guard selected == "system" else {
            return canonicalSupportedCode(for: selected) ?? "en"
        }

        for preferred in preferredLanguages {
            if let exact = canonicalSupportedCode(for: preferred) {
                return exact
            }
            let normalized = preferred.replacingOccurrences(of: "_", with: "-")
            if let chineseVariant = chineseVariantCode(for: normalized) {
                return chineseVariant
            }
            if let baseLanguage = normalized.split(separator: "-", maxSplits: 1).first,
               let fallback = canonicalSupportedCode(for: String(baseLanguage)) {
                return fallback
            }
        }
        return "en"
    }

    static func displayName(forTranslationCode code: String) -> String {
        let appLanguageCode: String
        switch code {
        case "zh-CN": appLanguageCode = "zh-Hans"
        case "zh-TW": appLanguageCode = "zh-Hant"
        default: appLanguageCode = code
        }
        return availableLanguages.first(where: { $0.code == appLanguageCode })?.name ?? code
    }

    private static func canonicalSupportedCode(for identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        return availableLanguages.first { language in
            language.code.caseInsensitiveCompare(normalized) == .orderedSame
        }?.code
    }

    private static func chineseVariantCode(for identifier: String) -> String? {
        let normalized = identifier.lowercased()
        guard normalized == "zh" || normalized.hasPrefix("zh-") else { return nil }
        if normalized.hasPrefix("zh-hant")
            || normalized.hasPrefix("zh-tw")
            || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        return "zh-Hans"
    }

    func localizedString(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private func reload() {
        let lang = resolvedLanguage
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            bundle = langBundle
        } else {
            bundle = .main
        }
    }
}

/// Shorthand for localized string lookup.
func L(_ key: String) -> String {
    LanguageManager.shared.localizedString(key)
}
