#!/usr/bin/env -S xcrun swift

import CryptoKit
import Foundation

private struct Options {
    var appVersion: String?
    var catalogURL: URL?
    var expectedCatalogPath: String?
    var publicKeyBase64: String?
    var deployedCatalogPath: String?
    var requiredPluginKitVersion: Int?
    var requiredSchemaVersion: Int?
}

private enum PreflightError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

private struct CatalogRequirement {
    let minimumAppVersion: String
    let url: URL
    let expectedCatalogPath: String
}

private let productionCatalogID = "com.ggbond.mactools.plugins"

private func fail(_ message: String) throws -> Never {
    throw PreflightError.message(message)
}

private func parseOptions() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        guard !arguments.isEmpty else {
            try fail("Missing value for \(option).")
        }
        let value = arguments.removeFirst()
        switch option {
        case "--app-version": options.appVersion = value
        case "--catalog-url": options.catalogURL = URL(string: value)
        case "--expected-catalog": options.expectedCatalogPath = value
        case "--public-key-base64": options.publicKeyBase64 = value
        case "--deployed-catalog": options.deployedCatalogPath = value
        case "--required-plugin-kit-version":
            guard let version = Int(value), version > 0 else {
                try fail("Invalid PluginKit version: \(value)")
            }
            options.requiredPluginKitVersion = version
        case "--required-schema-version":
            guard let version = Int(value), version > 0 else {
                try fail("Invalid catalog schema version: \(value)")
            }
            options.requiredSchemaVersion = version
        default: try fail("Unknown option: \(option)")
        }
    }
    guard options.appVersion != nil else {
        try fail("--app-version is required.")
    }
    return options
}

private func versionComponents(_ value: String) throws -> [Int] {
    let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
    let components = core.split(separator: ".")
    guard components.count == 3,
          components.allSatisfy({ Int($0) != nil })
    else {
        try fail("Invalid app version: \(value)")
    }
    return components.map { Int($0)! }
}

private func isVersion(_ value: String, atLeast minimum: String) throws -> Bool {
    try versionComponents(value).lexicographicallyPrecedes(versionComponents(minimum)) == false
}

private func sourcePluginKitVersion() throws -> Int {
    let pluginRoot = URL(fileURLWithPath: "Plugins", isDirectory: true)
    let directories = try FileManager.default.contentsOfDirectory(
        at: pluginRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    var versions = Set<Int>()
    for directory in directories {
        let manifestURL = directory.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
        let data = try Data(contentsOf: manifestURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let manifest = object as? [String: Any],
              let version = manifest["pluginKitVersion"] as? Int,
              version > 0 else {
            try fail("Cannot determine PluginKit version from \(manifestURL.path).")
        }
        versions.insert(version)
    }
    guard versions.count == 1, let version = versions.first else {
        try fail("Plugin manifests must declare one shared PluginKit version.")
    }
    return version
}

private func catalogRequirement(pluginKitVersion: Int) -> CatalogRequirement {
    let relativePath: String
    if pluginKitVersion == 2 {
        relativePath = "catalog.json"
    } else if pluginKitVersion == 5 {
        relativePath = "v5/schema3/catalog.json"
    } else {
        relativePath = "v\(pluginKitVersion)/catalog.json"
    }
    return CatalogRequirement(
        minimumAppVersion: pluginKitVersion >= 7 ? "1.3.1" : pluginKitVersion >= 6 ? "1.3.0" : "1.2.1",
        url: URL(string: "https://mactools.ggbond.app/plugins/\(relativePath)")!,
        expectedCatalogPath: "docs/plugins/\(relativePath)"
    )
}

private func releasePublicKey() throws -> String {
    let path = "Configs/Release.xcconfig"
    let contents: String
    do {
        contents = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        try fail("Cannot read \(path): \(error.localizedDescription)")
    }
    for line in contents.split(whereSeparator: \Character.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if parts.count == 2, parts[0] == "PLUGIN_CATALOG_PUBLIC_KEY", !parts[1].isEmpty {
            return parts[1]
        }
    }
    try fail("PLUGIN_CATALOG_PUBLIC_KEY is missing from \(path).")
}

private func fetch(_ url: URL) throws -> Data {
    guard url.scheme?.lowercased() == "https" else {
        try fail("Production plugin catalog URL must use HTTPS: \(url.absoluteString)")
    }
    let semaphore = DispatchSemaphore(value: 0)
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
    var result: Result<Data, Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .failure(error)
            return
        }
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let data
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = .failure(
                PreflightError.message("Catalog request returned HTTP \(status).")
            )
            return
        }
        result = .success(data)
    }.resume()
    guard semaphore.wait(timeout: .now() + 25) == .success,
          let result
    else {
        try fail("Timed out while fetching \(url.absoluteString).")
    }
    return try result.get()
}

private func readCatalog(at path: String) throws -> Data {
    guard FileManager.default.fileExists(atPath: path) else {
        try fail(
            "Required plugin catalog is missing: \(path). Publish the plugin batch first, "
                + "wait for the catalog deployment, then retry the app release."
        )
    }
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        try fail("Cannot read plugin catalog \(path): \(error.localizedDescription)")
    }
}

private func catalogObject(from data: Data, label: String) throws -> [String: Any] {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        try fail("\(label) is not valid JSON: \(error.localizedDescription)")
    }
    guard let catalog = object as? [String: Any] else {
        try fail("\(label) must contain a JSON object.")
    }
    return catalog
}

private func normalizedJSON(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
        try fail("Plugin catalog contains unsupported JSON values.")
    }
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func validateCatalog(
    _ data: Data,
    label: String,
    targetAppVersion: String,
    expectedCatalogID: String,
    expectedPluginKitVersion: Int,
    expectedSchemaVersion: Int,
    publicKeyBase64: String
) throws -> [String: Any] {
    var catalog = try catalogObject(from: data, label: label)
    guard let schemaVersion = catalog["schemaVersion"] as? Int,
          schemaVersion == expectedSchemaVersion else {
        try fail("\(label) must use catalog schema \(expectedSchemaVersion).")
    }
    guard catalog["pluginKitVersion"] as? Int == expectedPluginKitVersion else {
        try fail("\(label) does not target PluginKit \(expectedPluginKitVersion).")
    }
    guard let catalogID = catalog["catalogID"] as? String,
          catalogID == expectedCatalogID else {
        try fail("\(label) must use catalog ID \(expectedCatalogID).")
    }
    guard let minimumHostVersion = catalog["minimumHostVersion"] as? String,
          !minimumHostVersion.isEmpty else {
        try fail("\(label) has no minimum host version.")
    }
    _ = try versionComponents(minimumHostVersion)
    guard try isVersion(targetAppVersion, atLeast: minimumHostVersion) else {
        try fail(
            "\(label) requires MacTools \(minimumHostVersion), which is newer than "
                + "the target app \(targetAppVersion)."
        )
    }
    guard let plugins = catalog["plugins"] as? [[String: Any]], !plugins.isEmpty else {
        try fail("\(label) contains no plugin packages.")
    }
    var pluginIDs = Set<String>()
    for plugin in plugins {
        guard let id = plugin["id"] as? String, !id.isEmpty,
              pluginIDs.insert(id).inserted,
              plugin["pluginKitVersion"] as? Int == expectedPluginKitVersion,
              let package = plugin["package"] as? [String: Any],
              let urlValue = package["url"] as? String,
              URL(string: urlValue)?.scheme?.lowercased() == "https",
              let checksum = package["sha256"] as? String,
              checksum.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              let size = package["size"] as? NSNumber, size.int64Value > 0
        else {
            try fail("\(label) contains an invalid plugin entry.")
        }
    }
    guard let signature = catalog.removeValue(forKey: "signature") as? [String: Any],
          (signature["algorithm"] as? String)?.lowercased() == "ed25519",
          let signatureValue = signature["value"] as? String,
          let signatureData = Data(base64Encoded: signatureValue),
          signatureData.count == 64,
          let publicKeyData = Data(base64Encoded: publicKeyBase64),
          publicKeyData.count == 32
    else {
        try fail("\(label) has no valid Ed25519 signature metadata.")
    }
    let publicKey: Curve25519.Signing.PublicKey
    do {
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    } catch {
        try fail("Cannot construct the plugin catalog public key.")
    }
    let payload = try normalizedJSON(catalog)
    guard publicKey.isValidSignature(signatureData, for: payload) else {
        try fail("\(label) signature does not match the MacTools catalog public key.")
    }
    catalog["signature"] = signature
    return catalog
}

do {
    let options = try parseOptions()
    let appVersion = options.appVersion!
    let requiredPluginKitVersion = try options.requiredPluginKitVersion
        ?? sourcePluginKitVersion()
    let requirement = catalogRequirement(pluginKitVersion: requiredPluginKitVersion)
    guard try isVersion(appVersion, atLeast: requirement.minimumAppVersion) else {
        try fail(
            "This source uses catalog schema 3 and cannot be released as MacTools \(appVersion). "
                + "Raise the app version to \(requirement.minimumAppVersion) or later."
        )
    }

    let expectedPath = options.expectedCatalogPath ?? requirement.expectedCatalogPath
    let catalogURL = options.catalogURL ?? requirement.url
    let publicKey = try options.publicKeyBase64 ?? releasePublicKey()
    let requiredSchemaVersion = options.requiredSchemaVersion ?? 3
    let expectedData = try readCatalog(at: expectedPath)
    let deployedData = try options.deployedCatalogPath.map(readCatalog(at:)) ?? fetch(catalogURL)
    let expected = try validateCatalog(
        expectedData,
        label: "Committed plugin catalog",
        targetAppVersion: appVersion,
        expectedCatalogID: productionCatalogID,
        expectedPluginKitVersion: requiredPluginKitVersion,
        expectedSchemaVersion: requiredSchemaVersion,
        publicKeyBase64: publicKey
    )
    let deployed = try validateCatalog(
        deployedData,
        label: "Deployed plugin catalog",
        targetAppVersion: appVersion,
        expectedCatalogID: productionCatalogID,
        expectedPluginKitVersion: requiredPluginKitVersion,
        expectedSchemaVersion: requiredSchemaVersion,
        publicKeyBase64: publicKey
    )
    guard try normalizedJSON(expected) == normalizedJSON(deployed) else {
        try fail(
            "The deployed plugin catalog does not match \(expectedPath). "
                + "Wait for the plugin catalog deployment, then retry the app release."
        )
    }
    print(
        "Verified signed PluginKit \(requiredPluginKitVersion) catalog for "
            + "MacTools \(appVersion): \(catalogURL.absoluteString)"
    )
} catch {
    fputs("Plugin catalog preflight failed: \(error.localizedDescription)\n", stderr)
    fputs(
        "Release order: publish the compatible plugin batch and catalog, wait for deployment, "
            + "then publish the MacTools app.\n",
        stderr
    )
    exit(EXIT_FAILURE)
}
