import Foundation

/// Resolves localization resources without depending on a process-wide language list.
///
/// The app, dynamic plugins, and Finder Sync are separate targets, so this helper is
/// compiled into each of them instead of introducing a target dependency.
enum LocalizedBundleResolver {
    static func localizedBundles(
        in bundle: Bundle,
        preferredLanguages: [String],
        baseLanguage: String
    ) -> [Bundle] {
        let key = CacheKey(
            bundleURL: bundle.bundleURL,
            preferredLanguages: preferredLanguages,
            baseLanguage: baseLanguage
        )

        return cache.bundles(for: key) {
            var bundles: [Bundle] = []
            for language in preferredLanguages + [baseLanguage] {
                for candidate in candidateLanguageIdentifiers(for: language) {
                    guard let path = bundle.path(forResource: candidate, ofType: "lproj"),
                          let localizedBundle = Bundle(path: path)
                    else {
                        continue
                    }

                    if !bundles.contains(where: { $0.bundleURL == localizedBundle.bundleURL }) {
                        bundles.append(localizedBundle)
                    }
                    break
                }
            }
            return bundles
        }
    }

    static func candidateLanguageIdentifiers(for language: String) -> [String] {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        var candidates = [normalized]
        let components = normalized.split(separator: "-").map(String.init)

        if let languageCode = components.first {
            if languageCode == "zh" {
                let usesTraditional = components.contains("Hant")
                    || (!components.contains("Hans")
                        && components.contains(where: { ["HK", "MO", "TW"].contains($0) }))
                candidates.append(usesTraditional ? "zh-Hant" : "zh-Hans")
            }
            candidates.append(languageCode)
        }

        return candidates.reduce(into: []) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }

    /// Keeps the user's region, calendar, and format settings while changing
    /// only the language used by formatters.
    static func locale(for language: String?, currentLocale: Locale = .current) -> Locale {
        guard let language, !language.isEmpty else {
            return currentLocale
        }

        let suffix = currentLocale.identifier.drop {
            $0 != "_" && $0 != "@"
        }
        return Locale(identifier: language + suffix)
    }

    fileprivate struct CacheKey: Hashable {
        let bundleURL: URL
        let preferredLanguages: [String]
        let baseLanguage: String
    }

    private static let cache = LocalizedBundleCache()
}

private final class LocalizedBundleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LocalizedBundleResolver.CacheKey: [Bundle]] = [:]

    func bundles(
        for key: LocalizedBundleResolver.CacheKey,
        build: () -> [Bundle]
    ) -> [Bundle] {
        lock.withLock {
            if let value = values[key] {
                return value
            }

            let value = build()
            values[key] = value
            return value
        }
    }
}
