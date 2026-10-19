import Foundation
import XCTest
@testable import MacTools
@testable import MacToolsPluginKit

@MainActor
final class LocalizationResourceTests: XCTestCase {
    func testChineseTextHonorsExplicitScriptBeforeRegionalFallback() {
        let text = PluginLocalizedText(["en": "English", "zh-Hans": "Simplified", "zh-Hant": "Traditional"])
        let cases = [
            ("zh-Hans-TW", "Simplified"),
            ("zh_Hans_HK", "Simplified"),
            ("zh-Hans-MO", "Simplified"),
            ("zh-Hant-CN", "Traditional"),
            ("zh-TW", "Traditional"),
            ("zh-HK", "Traditional"),
            ("zh-MO", "Traditional"),
            ("zh-CN", "Simplified"),
        ]
        for (language, expected) in cases {
            XCTAssertEqual(text.localizedValue(preferredLanguages: [language]), expected, language)
        }
    }

    func testRuntimeTextLanguageRemainsIndependentOfFormattingRegion() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalizationTests-\(UUID())"))
        let source = PluginRuntimeLocaleSource(
            userDefaults: defaults,
            systemPreferredLanguages: { ["fr-FR", "en"] },
            currentLocale: { Locale(identifier: "en_TW") }
        )
        let text = PluginLocalizedText([
            "en": "English", "fr": "French", "zh-Hans": "Simplified", "zh-Hant": "Traditional",
        ])

        source.setPreference("zh-Hans")
        XCTAssertEqual(text.localizedValue(preferredLanguages: source.preferredLanguages), "Simplified")
        XCTAssertEqual(source.locale.region?.identifier, "TW")

        source.setPreference("system")
        XCTAssertEqual(text.localizedValue(preferredLanguages: source.preferredLanguages), "French")
        XCTAssertEqual(source.locale.identifier, "en_TW")
    }

    func testCatalogTranslationsAreAvailableFromCompiledResources() throws {
        let originalPreference = UserDefaults.standard.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey)
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hostResources = root.appendingPathComponent("Sources/Resources/Localization")
        var catalogs = try FileManager.default.contentsOfDirectory(at: hostResources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" && $0.lastPathComponent != "InfoPlist.xcstrings" }
            .map { ($0, Bundle.main) }
            + [(root.appendingPathComponent("Sources/MacToolsPluginKit/Resources/Localizable.xcstrings"),
                Bundle(for: PluginRuntimeLocaleSource.self))]

        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        catalogs.append((root.appendingPathComponent("Sources/Core/RightClick/RightClick.xcstrings"), Bundle.main))
        let intentsBundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("MacToolsAppIntents.framework")))
        let intentsResources = root.appendingPathComponent("Sources/MacToolsAppIntents/Resources")
        catalogs += try FileManager.default.contentsOfDirectory(at: intentsResources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
            .map { ($0, intentsBundle) }
        let plugins = root.appendingPathComponent("Plugins")
        for directory in try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            let resources = directory.appendingPathComponent("Resources")
            guard FileManager.default.fileExists(atPath: resources.path) else { continue }
            let urls = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "xcstrings" }
            guard !urls.isEmpty else { continue }
            let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent(directory.lastPathComponent + ".bundle")))
            catalogs += urls.map { ($0, bundle) }
        }

        for (url, bundle) in catalogs {
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
            let languages = Set(strings.values.flatMap {
                ($0["localizations"] as? [String: Any])?.keys.map { $0 } ?? []
            })
            for language in languages {
                PluginRuntimeLocalization.source.setPreference(language)
                for (key, entry) in strings {
                    let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
                    // Plural rules are compiled into stringsdict resources and
                    // exercised by the feature tests that supply their counts.
                    guard let unit = localizations[language]?["stringUnit"] as? [String: Any],
                          let expected = unit["value"] as? String else { continue }
                    XCTAssertEqual(
                        PluginRuntimeLocalization.string(
                            key, defaultValue: UUID().uuidString,
                            table: url.deletingPathExtension().lastPathComponent, bundle: bundle
                        ),
                        expected,
                        "\(url.lastPathComponent): \(key) [\(language)]"
                    )
                }
            }
        }
    }
}
