import XCTest
@testable import MacTools

final class PluginPackageManifestTests: XCTestCase {
    func testManifestValidationAcceptsCurrentPackageFormat() throws {
        for minimumHostVersion in ["2.0.0", "2.0.1"] {
            let manifest = PluginPackageManifest(
                id: "com.example.demo",
                displayName: "Demo",
                version: "1.0.0",
                minHostVersion: minimumHostVersion,
                pluginKitVersion: 7,
                bundleRelativePath: "Demo.bundle",
                capabilities: .init(panelItems: [.row])
            )

            XCTAssertNoThrow(try PluginPackageManifestLoader.validate(manifest, hostVersion: "2.0.1"))
        }
    }

    func testManifestValidationRejectsPreviousPluginKitVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            pluginKitVersion: 1,
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .unsupportedPluginKitVersion(1))
        }
    }

    func testManifestValidationRejectsUnsafeBundlePath() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            bundleRelativePath: "../Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .invalidBundleRelativePath("../Demo.bundle"))
        }
    }

    func testManifestValidationRejectsReservedOrTerminatedPluginIdentifiers() {
        for id in ["marketplace", "fan-control\n", "fan-control\r"] {
            let manifest = PluginPackageManifest(
                id: id,
                displayName: "Demo",
                version: "1.0.0",
                minHostVersion: "0.15.0",
                bundleRelativePath: "Demo.bundle"
            )

            XCTAssertThrowsError(
                try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")
            ) { error in
                XCTAssertEqual(error as? PluginPackageManifestError, .invalidIdentifier(id))
            }
        }
    }

    func testManifestValidationRejectsIncompatibleHostVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(
                error as? PluginPackageManifestError,
                .incompatibleHostVersion(required: "1.0.0", current: "0.16.0")
            )
        }
    }

    func testManifestDecodesPrivateDataRemovalPolicy() throws {
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "1.2.0",
          "pluginKitVersion": 5,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": { "primaryPanel": true, "componentPanel": false, "settings": "workspace" },
          "permissions": [],
          "uninstallDataPolicy": "removePrivateData",
          "presentation": {
            "publisher": "Clipboard Tests",
            "longDescription": { "en": "Encrypted clipboard history" },
            "examples": [],
            "screenshots": [],
            "license": "Apache-2.0"
          }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: json)

        XCTAssertEqual(manifest.effectiveUninstallDataPolicy, .removePrivateData)
        XCTAssertEqual(manifest.presentation?.publisher, "Clipboard Tests")
    }

}

enum PluginSourceManifestTestProjection {
    static func data(pluginDirectoryName: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
            .appendingPathComponent("plugin.json")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactools-manifest-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destinationURL = temporaryDirectory.appendingPathComponent("plugin.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.currentDirectoryURL = repositoryRoot
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/plugins/copy-plugin-manifest.py").path,
            "copy",
            "--source", sourceURL.path,
            "--destination", destinationURL.path,
            "--configuration", "Release",
            "--app-version-config",
            repositoryRoot.appendingPathComponent("Configs/AppVersion.xcconfig").path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown projection error"
            throw projectionError(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Data(contentsOf: destinationURL)
    }

    private static func projectionError(_ message: String) -> NSError {
        NSError(
            domain: "PluginSourceManifestTestProjection",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
