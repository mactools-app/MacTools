import Foundation
import MacToolsPluginKit

struct DynamicPluginLoadResult {
    let record: PluginPackageRecord
    let plugins: [any MacToolsPlugin]
    let errorMessage: String?
}

@MainActor
protocol DynamicPluginLoading: AnyObject {
    var preparePluginForActivation: ((any MacToolsPlugin) -> Void)? { get set }
    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult]
}

@MainActor
final class DynamicPluginLoader: DynamicPluginLoading {
    var preparePluginForActivation: ((any MacToolsPlugin) -> Void)?
    private let packageStore: PluginPackageStore
    private let trustValidator: PluginTrustValidating

    init(
        packageStore: PluginPackageStore,
        trustValidator: PluginTrustValidating = SameTeamPluginTrustValidator()
    ) {
        self.packageStore = packageStore
        self.trustValidator = trustValidator
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        records.map { record in
            guard case .installed = record.state else {
                return DynamicPluginLoadResult(record: record, plugins: [], errorMessage: nil)
            }

            var plugins: [any MacToolsPlugin] = []
            var activationAttemptedCount = 0
            do {
                try packageStore.requirementChecker.validate(record.manifest.requirements)
                let provider = try PluginInvocationGuard
                    .value(operation: "load provider for \(record.id)") {
                        try loadProvider(for: record)
                    }
                    .get()
                let context = packageStore.runtimeContext(for: record)
                plugins = try PluginInvocationGuard
                    .value(operation: "make plugins for \(record.id)") {
                        provider.makePlugins()
                    }
                    .get()
                try Self.validateLoadedPlugins(plugins, for: record)

                for plugin in plugins {
                    activationAttemptedCount += 1
                    try activatePlugin(plugin, context: context)
                }

                return DynamicPluginLoadResult(record: record, plugins: plugins, errorMessage: nil)
            } catch {
                Self.deactivateAfterFailedLoad(
                    Array(plugins.prefix(activationAttemptedCount)),
                    recordID: record.id
                )
                return DynamicPluginLoadResult(
                    record: record,
                    plugins: [],
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    func activatePlugin(_ plugin: any MacToolsPlugin, context: PluginRuntimeContext) throws {
        try PluginInvocationGuard
            .run(operation: "activate plugin \(plugin.metadata.id)") {
                self.preparePluginForActivation?(plugin)
                plugin.activate(context: context)
            }
            .get()
    }

    static func deactivateAfterFailedLoad(
        _ plugins: [any MacToolsPlugin],
        recordID: String
    ) {
        for plugin in plugins {
            _ = PluginInvocationGuard
                .run(operation: "deactivate failed plugin \(recordID)") {
                    plugin.deactivate(reason: .disabled)
                }
            plugin.onStateChange = nil
            plugin.requestPermissionGuidance = nil
            plugin.shortcutBindingResolver = nil
        }
    }

    private func loadProvider(for record: PluginPackageRecord) throws -> any PluginProvider {
        try trustValidator.validatePluginBundle(at: record.bundleURL)

        guard let bundle = Bundle(url: record.bundleURL) else {
            throw DynamicPluginLoaderError.unreadableBundle(record.bundleURL)
        }

        do {
            try bundle.loadAndReturnError()
        } catch {
            throw DynamicPluginLoaderError.loadFailed(
                record.bundleURL,
                reason: error.localizedDescription
            )
        }

        let context = packageStore.runtimeContext(for: record)

        if let className = record.manifest.factoryClass,
           let factoryClass = NSClassFromString(className) as? MacToolsPluginBundleFactory.Type {
            return try factoryClass.makeProvider(context: context)
        }

        guard let factoryClass = bundle.principalClass as? MacToolsPluginBundleFactory.Type else {
            throw DynamicPluginLoaderError.missingFactory(record.manifest.displayName)
        }

        return try factoryClass.makeProvider(context: context)
    }

    static func validateLoadedPlugins(
        _ plugins: [any MacToolsPlugin],
        for record: PluginPackageRecord
    ) throws {
        guard plugins.count == 1 else {
            throw DynamicPluginLoaderError.invalidPluginCount(
                expected: record.manifest.id,
                actual: plugins.count
            )
        }

        guard let plugin = plugins.first else {
            return
        }

        guard plugin.metadata.id == record.manifest.id else {
            throw DynamicPluginLoaderError.pluginIdentifierMismatch(
                expected: record.manifest.id,
                actual: plugin.metadata.id
            )
        }
    }
}

enum DynamicPluginLoaderError: LocalizedError, Equatable {
    case unreadableBundle(URL)
    case loadFailed(URL, reason: String)
    case missingFactory(String)
    case invalidPluginCount(expected: String, actual: Int)
    case pluginIdentifierMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableBundle(url):
            return AppL10n.pluginsFormat("plugin.error.loader.unreadableBundleFormat", defaultValue: "无法读取插件 bundle：%@", url.path)
        case let .loadFailed(url, reason):
            let summary = AppL10n.pluginsFormat(
                "plugin.error.loader.loadFailedFormat",
                defaultValue: "插件代码加载失败：%@",
                url.path
            )
            return "\(summary) (\(reason))"
        case let .missingFactory(name):
            return AppL10n.pluginsFormat("plugin.error.loader.missingFactoryFormat", defaultValue: "插件缺少入口工厂：%@", name)
        case let .invalidPluginCount(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.loader.invalidPluginCountFormat",
                defaultValue: "插件包 %@ 必须返回 1 个插件，实际返回 %d 个。",
                expected,
                actual
            )
        case let .pluginIdentifierMismatch(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.loader.identifierMismatchFormat",
                defaultValue: "插件 ID 不匹配，manifest 为 %@，运行时代码为 %@。",
                expected,
                actual
            )
        }
    }
}
