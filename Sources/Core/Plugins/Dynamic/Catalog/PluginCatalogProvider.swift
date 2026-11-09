import Foundation

enum PluginCatalogSource: Equatable {
    case production(URL)
    case localDevelopment(URL)

    var url: URL {
        switch self {
        case let .production(url), let .localDevelopment(url):
            return url
        }
    }

    var sourceKind: PluginCatalogSnapshot.SourceKind {
        switch self {
        case .production:
            return .production
        case .localDevelopment:
            return .localDevelopment
        }
    }
}

@MainActor
protocol PluginCatalogProviding {
    func loadCatalog() async throws -> PluginCatalogSnapshot
}

struct PluginCatalogProviderConfiguration {
    // PluginKit 2 used the original unversioned URL. Keep it stable so older
    // app releases continue to receive the catalog format they understand.
    static let legacyProductionCatalogURL = URL(string: "https://mactools.ggbond.app/plugins/catalog.json")!

    static func productionCatalogURL(for pluginKitVersion: Int) -> URL {
        if pluginKitVersion == 2 {
            return legacyProductionCatalogURL
        }

        return URL(string: "https://mactools.ggbond.app/plugins/v\(pluginKitVersion)/catalog.json")!
    }

    static func nightlyCatalogURL(for pluginKitVersion: Int) -> URL {
        URL(string: "https://mactools.ggbond.app/nightly/plugins/v\(pluginKitVersion)/catalog.json")!
    }

    // Schema 3 lives on its own compatibility endpoint so released PluginKit 5
    // hosts can keep reading the immutable schema-2 catalog they understand.
    static let schema3ProductionCatalogURL = URL(
        string: "https://mactools.ggbond.app/plugins/v5/schema3/catalog.json"
    )!

    static func productionCatalogURL(
        forHostVersion hostVersion: String,
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion
    ) -> URL {
        guard pluginKitVersion == 5 else {
            return productionCatalogURL(for: pluginKitVersion)
        }
        guard PluginVersionComparator.isVersion(hostVersion, atLeast: "1.2.1") else {
            return productionCatalogURL(for: pluginKitVersion)
        }
        return schema3ProductionCatalogURL
    }

    static func configuredProductionCatalogURL(
        for pluginKitVersion: Int,
        hostVersion: String = AppMetadata.shortVersion ?? "0",
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        if let rawURL = infoDictionary?["MTPluginCatalogURL"] as? String,
           !rawURL.contains("$("),
           let url = URL(string: rawURL),
           url.scheme?.lowercased() == "https" {
            return url
        }

        if infoDictionary?["MTReleaseChannel"] as? String == "nightly" {
            return nightlyCatalogURL(for: pluginKitVersion)
        }

        return productionCatalogURL(
            forHostVersion: hostVersion,
            pluginKitVersion: pluginKitVersion
        )
    }

    static func defaultSource(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostVersion: String = AppMetadata.shortVersion ?? "0"
    ) -> PluginCatalogSource {
        #if DEBUG
        if let rawURL = environment["MACTOOLS_PLUGIN_CATALOG_URL"],
           let url = URL(string: rawURL) {
            return source(forEnvironmentCatalogURL: url)
        }

        if FileManager.default.fileExists(atPath: defaultLocalDevelopmentCatalogURL.path) {
            return .localDevelopment(defaultLocalDevelopmentCatalogURL)
        }
        #endif

        return .production(configuredProductionCatalogURL(
            for: PluginPackageManifestLoader.supportedPluginKitVersion,
            hostVersion: hostVersion
        ))
    }

    private static func source(forEnvironmentCatalogURL url: URL) -> PluginCatalogSource {
        if url.isFileURL {
            return .localDevelopment(url)
        }

        return .production(url)
    }

    static var defaultLocalDevelopmentCatalogURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("LocalPlugins", isDirectory: true)
            .appendingPathComponent("catalog.dev.json", isDirectory: false)
    }
}

struct RemotePluginCatalogProvider: PluginCatalogProviding {
    private let url: URL
    private let session: URLSession
    private let verifier: PluginCatalogVerifier
    private let now: () -> Date

    init(
        url: URL,
        session: URLSession = .shared,
        verifier: PluginCatalogVerifier = .production(),
        now: @escaping () -> Date = Date.init
    ) {
        self.url = url
        self.session = session
        self.verifier = verifier
        self.now = now
    }

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadRevalidatingCacheData

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw PluginCatalogProviderError.httpStatus(httpResponse.statusCode)
        }

        let catalog = try PluginCatalogCoding.decoder.decode(PluginCatalog.self, from: data)
        try verifier.verify(catalog, sourceKind: .production, rawData: data)

        return PluginCatalogSnapshot(
            catalog: catalog,
            sourceURL: url,
            sourceKind: .production,
            loadedAt: now()
        )
    }
}

struct LocalPluginCatalogProvider: PluginCatalogProviding {
    private let url: URL
    private let verifier: PluginCatalogVerifier
    private let now: () -> Date

    init(
        url: URL,
        verifier: PluginCatalogVerifier = .localDevelopment(),
        now: @escaping () -> Date = Date.init
    ) {
        self.url = url
        self.verifier = verifier
        self.now = now
    }

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        guard url.isFileURL else {
            throw PluginCatalogProviderError.localCatalogMustUseFileURL(url)
        }

        let data = try Data(contentsOf: url)
        let catalog = try PluginCatalogCoding.decoder.decode(PluginCatalog.self, from: data)
        try verifier.verify(catalog, sourceKind: .localDevelopment, rawData: data)

        return PluginCatalogSnapshot(
            catalog: catalog,
            sourceURL: url,
            sourceKind: .localDevelopment,
            loadedAt: now()
        )
    }
}

enum PluginCatalogProviderFactory {
    @MainActor
    static func makeProvider(
        source: PluginCatalogSource = PluginCatalogProviderConfiguration.defaultSource()
    ) -> any PluginCatalogProviding {
        switch source {
        case let .production(url):
            return RemotePluginCatalogProvider(url: url)
        case let .localDevelopment(url):
            return LocalPluginCatalogProvider(url: url)
        }
    }
}

enum PluginCatalogProviderError: LocalizedError, Equatable {
    case localCatalogMustUseFileURL(URL)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .localCatalogMustUseFileURL(url):
            return AppL10n.pluginsFormat(
                "plugin.error.catalog.localMustUseFileURLFormat",
                defaultValue: "本地开发插件列表必须使用 file:// 地址：%@",
                url.absoluteString
            )
        case let .httpStatus(statusCode):
            return AppL10n.pluginsFormat("plugin.error.catalog.httpStatusFormat", defaultValue: "插件列表读取失败：HTTP %d", statusCode)
        }
    }
}
