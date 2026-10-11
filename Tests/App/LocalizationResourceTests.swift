import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class LocalizationResourceTests: XCTestCase {
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
