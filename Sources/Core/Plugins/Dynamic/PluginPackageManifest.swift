import Foundation
import MacToolsPluginKit

struct PluginPackageManifest: Codable, Equatable {
    enum UninstallDataPolicy: String, Codable, Equatable {
        case preserve
        case removePrivateData
    }

    struct Capabilities: Codable, Equatable {
        enum Settings: String, Codable, CaseIterable {
            case none
            case form
            case workspace

            var layout: PluginSettingsLayout? {
                switch self {
                case .none:
                    return nil
                case .form:
                    return .form
                case .workspace:
                    return .workspace
                }
            }
        }

        let panelItems: [PluginPanelItemKind]
        let settings: Settings

        init(
            panelItems: [PluginPanelItemKind] = [],
            settings: Settings = .none
        ) {
            self.panelItems = panelItems
            self.settings = settings
        }

        private enum CodingKeys: String, CodingKey {
            case panelItems
            case primaryPanel
            case componentPanel
            case settings
            case configuration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let kinds = try container.decodeIfPresent([PluginPanelItemKind].self, forKey: .panelItems) {
                panelItems = kinds
            } else {
                // Decode retired envelopes so incompatible installed packages can be updated.
                var kinds: [PluginPanelItemKind] = []
                if try container.decodeIfPresent(Bool.self, forKey: .primaryPanel) == true { kinds.append(.row) }
                if try container.decodeIfPresent(Bool.self, forKey: .componentPanel) == true { kinds.append(.widget) }
                panelItems = kinds
            }
            if let settings = try container.decodeIfPresent(Settings.self, forKey: .settings) {
                self.settings = settings
            } else {
                // The package store must still decode a v3 envelope before it can
                // identify the ABI mismatch and update the package. This does not
                // expose or render the removed v3 settings API.
                let hadConfiguration = try container.decodeIfPresent(
                    Bool.self,
                    forKey: .configuration
                ) ?? false
                settings = hadConfiguration ? .form : .none
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(panelItems, forKey: .panelItems)
            try container.encode(settings, forKey: .settings)
        }
    }

    let id: String
    let displayName: String
    let version: String
    let minHostVersion: String
    let pluginKitVersion: Int
    let bundleRelativePath: String
    let factoryClass: String?
    let capabilities: Capabilities
    let permissions: [String]
    let category: String?
    let releaseChannel: String?
    let localizedMetadata: [String: PluginLocalizedMetadata]?
    let uninstallDataPolicy: UninstallDataPolicy?
    let presentation: PluginProductMetadata.Presentation?
    let discovery: PluginProductMetadata.Discovery?
    let requirements: PluginProductMetadata.Requirements?
    let privacy: PluginProductMetadata.Privacy?
    let actions: PluginProductMetadata.Actions?
    let setup: PluginProductMetadata.Setup?
    let relationships: PluginProductMetadata.Relationships?

    init(
        id: String,
        displayName: String,
        version: String,
        minHostVersion: String,
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        bundleRelativePath: String,
        factoryClass: String? = nil,
        capabilities: Capabilities = Capabilities(),
        permissions: [String] = [],
        category: String? = nil,
        releaseChannel: String? = nil,
        localizedMetadata: [String: PluginLocalizedMetadata]? = nil,
        uninstallDataPolicy: UninstallDataPolicy? = nil,
        presentation: PluginProductMetadata.Presentation? = nil,
        discovery: PluginProductMetadata.Discovery? = nil,
        requirements: PluginProductMetadata.Requirements? = nil,
        privacy: PluginProductMetadata.Privacy? = nil,
        actions: PluginProductMetadata.Actions? = nil,
        setup: PluginProductMetadata.Setup? = nil,
        relationships: PluginProductMetadata.Relationships? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.minHostVersion = minHostVersion
        self.pluginKitVersion = pluginKitVersion
        self.bundleRelativePath = bundleRelativePath
        self.factoryClass = factoryClass
        self.capabilities = capabilities
        self.permissions = permissions
        self.category = category
        self.releaseChannel = releaseChannel
        self.localizedMetadata = localizedMetadata
        self.uninstallDataPolicy = uninstallDataPolicy
        self.presentation = presentation
        self.discovery = discovery
        self.requirements = requirements
        self.privacy = privacy
        self.actions = actions
        self.setup = setup
        self.relationships = relationships
    }

    var effectiveUninstallDataPolicy: UninstallDataPolicy {
        uninstallDataPolicy ?? .preserve
    }

    var localizedDisplayName: String {
        PluginLocalizationMatcher.localizedMetadata(from: localizedMetadata ?? [:])?.displayName ?? displayName
    }

    var localizedSummary: String? {
        PluginLocalizationMatcher.localizedMetadata(from: localizedMetadata ?? [:])?.summary
    }
}

enum PluginPackageManifestError: LocalizedError, Equatable {
    case missingManifest(URL)
    case unreadableManifest(URL)
    case invalidIdentifier(String)
    case invalidVersion(String)
    case invalidBundleRelativePath(String)
    case unsupportedPluginKitVersion(Int)
    case incompatibleHostVersion(required: String, current: String)
    case incompatiblePluginVersion(required: String, current: String)

    var errorDescription: String? {
        switch self {
        case let .missingManifest(url):
            return AppL10n.pluginsFormat("plugin.error.manifest.missingFormat", defaultValue: "插件缺少 manifest：%@", url.path)
        case let .unreadableManifest(url):
            return AppL10n.pluginsFormat("plugin.error.manifest.unreadableFormat", defaultValue: "插件 manifest 无法读取：%@", url.path)
        case let .invalidIdentifier(id):
            return AppL10n.pluginsFormat("plugin.error.manifest.invalidIdentifierFormat", defaultValue: "插件 ID 不合法：%@", id)
        case let .invalidVersion(version):
            return AppL10n.pluginsFormat("plugin.error.manifest.invalidVersionFormat", defaultValue: "插件版本号不合法：%@", version)
        case let .invalidBundleRelativePath(path):
            return AppL10n.pluginsFormat("plugin.error.manifest.invalidBundlePathFormat", defaultValue: "插件入口路径不合法：%@", path)
        case let .unsupportedPluginKitVersion(version):
            return AppL10n.pluginsFormat("plugin.error.manifest.unsupportedSDKFormat", defaultValue: "插件 SDK 版本不支持：%d", version)
        case let .incompatibleHostVersion(required, current):
            return AppL10n.pluginsFormat(
                "plugin.error.manifest.incompatibleHostFormat",
                defaultValue: "插件需要 MacTools %@ 或更高版本，当前版本为 %@。",
                required,
                current
            )
        case let .incompatiblePluginVersion(required, current):
            return AppL10n.pluginsFormat(
                "plugin.error.manifest.incompatiblePluginFormat",
                defaultValue: "请更新插件至 %@ 或更高版本，当前版本为 %@。",
                required,
                current
            )
        }
    }
}

enum PluginPackageManifestLoader {
    static let fileName = "plugin.json"
    static let supportedPluginKitVersion = PluginKitCompatibility.currentVersion
    private static let minimumPluginVersions = [
        "middle-click": "2.0.2",
        "trackpad-gestures": "2.0.2",
    ]

    static func load(
        from packageURL: URL,
        hostVersion: String = AppMetadata.shortVersion ?? "0"
    ) throws -> PluginPackageManifest {
        let manifest = try readManifest(from: packageURL)
        try validate(manifest, hostVersion: hostVersion)
        return manifest
    }

    static func decode(from packageURL: URL) throws -> PluginPackageManifest {
        try readManifest(from: packageURL)
    }

    static func validate(_ manifest: PluginPackageManifest, hostVersion: String) throws {
        try validatePackageIdentity(manifest)

        guard manifest.pluginKitVersion == supportedPluginKitVersion else {
            throw PluginPackageManifestError.unsupportedPluginKitVersion(manifest.pluginKitVersion)
        }

        guard PluginVersionComparator.isVersion(hostVersion, atLeast: manifest.minHostVersion) else {
            throw PluginPackageManifestError.incompatibleHostVersion(
                required: manifest.minHostVersion,
                current: hostVersion
            )
        }
        if let failure = pluginVersionFailure(id: manifest.id, version: manifest.version, hostVersion: hostVersion) {
            throw failure
        }
    }

    static func pluginVersionFailure(id: String, version: String, hostVersion: String) -> PluginPackageManifestError? {
        // Host 2.0.2 owns shared trackpad input. Older gesture packages retain
        // independent native listeners and must be updated before activation.
        guard PluginVersionComparator.isVersion(hostVersion, atLeast: "2.0.2"),
              let required = minimumPluginVersions[id],
              !PluginVersionComparator.isVersion(version, atLeast: required) else { return nil }
        return .incompatiblePluginVersion(required: required, current: version)
    }

    static func validatePackageIdentity(_ manifest: PluginPackageManifest) throws {
        guard isValidPluginID(manifest.id) else {
            throw PluginPackageManifestError.invalidIdentifier(manifest.id)
        }

        guard isValidVersion(manifest.version) else {
            throw PluginPackageManifestError.invalidVersion(manifest.version)
        }

        guard isValidVersion(manifest.minHostVersion) else {
            throw PluginPackageManifestError.invalidVersion(manifest.minHostVersion)
        }

        guard
            !manifest.bundleRelativePath.isEmpty,
            !manifest.bundleRelativePath.hasPrefix("/"),
            !manifest.bundleRelativePath.split(separator: "/").contains("..")
        else {
            throw PluginPackageManifestError.invalidBundleRelativePath(manifest.bundleRelativePath)
        }
    }

    static func isValidPluginID(_ id: String) -> Bool {
        guard id != "marketplace" else {
            return false
        }

        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{1,126}[A-Za-z0-9]\z"#
        return id.range(of: pattern, options: .regularExpression) == id.startIndex..<id.endIndex
    }

    private static func isValidVersion(_ version: String) -> Bool {
        let pattern = #"^[0-9]+(?:\.[0-9]+){0,2}\z"#
        return version.range(of: pattern, options: .regularExpression) == version.startIndex..<version.endIndex
    }

    private static func readManifest(from packageURL: URL) throws -> PluginPackageManifest {
        let manifestURL = packageURL.appendingPathComponent(fileName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PluginPackageManifestError.missingManifest(manifestURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PluginPackageManifestError.unreadableManifest(manifestURL)
        }

        do {
            return try JSONDecoder().decode(PluginPackageManifest.self, from: data)
        } catch {
            throw PluginPackageManifestError.unreadableManifest(manifestURL)
        }
    }

}
