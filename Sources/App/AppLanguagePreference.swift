import Foundation
import MacToolsPluginKit

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case es
    case fr
    case ru
    case pt
    case de
    case ja
    case ko
    case ar
    case tr

    static let userDefaultsKey = "app.languagePreference"

    private static let appleLanguagesKey = "AppleLanguages"
    private static let rightClickFinderSyncBundleSuffix = ".right-click.finder-sync"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return AppL10n.settings("language.system", defaultValue: "跟随系统")
        case .zhHans:
            return AppL10n.settings("language.zh-Hans", defaultValue: "简体中文")
        case .zhHant:
            return AppL10n.settings("language.zh-Hant", defaultValue: "繁體中文")
        case .en:
            return AppL10n.settings("language.en", defaultValue: "English")
        case .es:
            return AppL10n.settings("language.es", defaultValue: "Español")
        case .fr:
            return AppL10n.settings("language.fr", defaultValue: "Français")
        case .ru:
            return AppL10n.settings("language.ru", defaultValue: "Русский")
        case .pt:
            return AppL10n.settings("language.pt", defaultValue: "Português")
        case .de:
            return AppL10n.settings("language.de", defaultValue: "Deutsch")
        case .ja:
            return AppL10n.settings("language.ja", defaultValue: "日本語")
        case .ko:
            return AppL10n.settings("language.ko", defaultValue: "한국어")
        case .ar:
            return AppL10n.settings("language.ar", defaultValue: "العربية")
        case .tr:
            return AppL10n.settings("language.tr", defaultValue: "Türkçe")
        }
    }

    /// A language picker option combines the name as written in the system's
    /// language with the language's own name, so it remains recognizable even
    /// when the app is currently displayed in another language.
    var pickerTitle: String {
        pickerTitle(systemLanguageIdentifier: Self.systemPreferredLanguageIdentifier)
    }

    func pickerTitle(systemLanguageIdentifier: String) -> String {
        switch self {
        case .system:
            let languageCode = Locale(identifier: systemLanguageIdentifier).language.languageCode?.identifier
                ?? systemLanguageIdentifier
            let systemLanguageName = Self.localizedLanguageName(
                for: languageCode,
                in: systemLanguageIdentifier
            )
            return "\(title) (\(systemLanguageName))"
        default:
            let localizedName = Self.localizedLanguageName(
                for: localeIdentifier,
                in: systemLanguageIdentifier
            )
            let nativeName = nativeTitle
            return localizedName == nativeName ? nativeName : "\(localizedName) / \(nativeName)"
        }
    }

    var appleLanguagesOverride: [String]? {
        switch self {
        case .system:
            return nil
        case .zhHans:
            return ["zh-Hans"]
        case .zhHant:
            return ["zh-Hant"]
        case .en:
            return ["en"]
        case .es:
            return ["es"]
        case .fr:
            return ["fr"]
        case .ru:
            return ["ru"]
        case .pt:
            return ["pt"]
        case .de:
            return ["de"]
        case .ja:
            return ["ja"]
        case .ko:
            return ["ko"]
        case .ar:
            return ["ar"]
        case .tr:
            return ["tr"]
        }
    }

    private var localeIdentifier: String {
        switch self {
        case .system:
            Self.systemPreferredLanguageIdentifier
        case .zhHans:
            "zh-Hans"
        case .zhHant:
            "zh-Hant"
        case .en:
            "en"
        case .es:
            "es"
        case .fr:
            "fr"
        case .ru:
            "ru"
        case .pt:
            "pt-BR"
        case .de:
            "de"
        case .ja:
            "ja"
        case .ko:
            "ko"
        case .ar:
            "ar"
        case .tr:
            "tr"
        }
    }

    private var nativeTitle: String {
        switch self {
        case .system:
            title
        case .zhHans:
            "简体中文"
        case .zhHant:
            "繁體中文"
        case .en:
            "English"
        case .es:
            "Español"
        case .fr:
            "Français"
        case .ru:
            "Русский"
        case .pt:
            "Português (Brasil)"
        case .de:
            "Deutsch"
        case .ja:
            "日本語"
        case .ko:
            "한국어"
        case .ar:
            "العربية"
        case .tr:
            "Türkçe"
        }
    }

    func store(in userDefaults: UserDefaults = .standard) {
        userDefaults.set(rawValue, forKey: Self.userDefaultsKey)
        applyAppleLanguagesOverride(in: userDefaults)
        userDefaults.synchronize()
        PluginRuntimeLocalization.source.setPreference(rawValue)
    }

    func applyAppleLanguagesOverride(in userDefaults: UserDefaults = .standard) {
        if let appleLanguagesOverride {
            userDefaults.set(appleLanguagesOverride, forKey: Self.appleLanguagesKey)
        } else {
            userDefaults.removeObject(forKey: Self.appleLanguagesKey)
        }

        if let extensionBundleIdentifier = Self.rightClickFinderSyncBundleIdentifier() {
            Self.applyAppleLanguagesOverride(
                appleLanguagesOverride,
                toBundleIdentifier: extensionBundleIdentifier
            )
        }
        Self.applyRightClickFinderSyncLanguageOverride(appleLanguagesOverride)
    }

    static func stored(in userDefaults: UserDefaults = .standard) -> AppLanguagePreference {
        guard
            let rawValue = userDefaults.string(forKey: userDefaultsKey),
            let preference = AppLanguagePreference(rawValue: rawValue)
        else {
            return .system
        }

        return preference
    }

    static func applyStoredPreference(userDefaults: UserDefaults = .standard) {
        let preference = stored(in: userDefaults)
        preference.applyAppleLanguagesOverride(in: userDefaults)
        PluginRuntimeLocalization.source.setPreference(preference.rawValue)
    }

    private static var systemPreferredLanguageIdentifier: String {
        let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let languages = globalDomain?[appleLanguagesKey] as? [String],
           let language = languages.first,
           !language.isEmpty {
            return language
        }

        return Locale.current.identifier
    }

    private static func localizedLanguageName(
        for languageIdentifier: String,
        in displayLanguageIdentifier: String
    ) -> String {
        let displayLocale = Locale(identifier: displayLanguageIdentifier)
        return displayLocale.localizedString(forIdentifier: languageIdentifier)
            ?? displayLocale.localizedString(
                forLanguageCode: Locale(identifier: languageIdentifier).language.languageCode?.identifier
                    ?? languageIdentifier
            )
            ?? languageIdentifier
    }

    private static func rightClickFinderSyncBundleIdentifier(bundle: Bundle = .main) -> String? {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        return bundleIdentifier + rightClickFinderSyncBundleSuffix
    }

    private static func applyAppleLanguagesOverride(
        _ appleLanguagesOverride: [String]?,
        toBundleIdentifier bundleIdentifier: String
    ) {
        let key = appleLanguagesKey as CFString
        let applicationID = bundleIdentifier as CFString
        let value = appleLanguagesOverride.map { $0 as CFArray }
        CFPreferencesSetValue(
            key,
            value,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesAppSynchronize(applicationID)
    }

    private static func applyRightClickFinderSyncLanguageOverride(_ appleLanguagesOverride: [String]?) {
        var configuration = RightClickConfigurationStore.load()
        guard configuration.preferredLanguages != appleLanguagesOverride else {
            return
        }

        configuration.preferredLanguages = appleLanguagesOverride
        RightClickConfigurationStore.save(configuration)
    }
}
