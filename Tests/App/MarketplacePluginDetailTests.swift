import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class MarketplacePluginDetailTests: XCTestCase {
    func testColdDetailLinkOpensBeforeCatalogLoadAndResolvesAfterRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MarketplacePluginDetailTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = URL(string: "https://example.com/catalog.json")!
        let provider = DetailCatalogProvider(snapshot: PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "details-test", generatedAt: .distantPast, minimumHostVersion: "1.0.0",
                plugins: [PluginCatalogEntry(
                    id: "catalog-tool", displayName: "Catalog Tool", summary: "Tool details",
                    version: "1.0.0", minimumHostVersion: "1.0.0",
                    package: .init(url: source, sha256: String(repeating: "a", count: 64), size: 1),
                    actions: .init(providers: [.init(
                        id: "catalog-tool", kind: "static", staticActions: [.init(
                            id: "show", title: .init(["en": "Show"]), description: .init(["en": "Show tool"]),
                            keywords: [], systemImage: "shippingbox", parameters: [], parameterSummary: nil,
                            permissionIDs: [], risk: "safe", surfaces: [], automaticEligible: false,
                            externalInvocation: "unavailable"
                        )], dynamicTemplates: []
                    )])
                )]
            ), sourceURL: source, sourceKind: .production, loadedAt: .distantPast
        ))
        provider.error = URLError(.notConnectedToInternet)
        let dynamicManager = DynamicPluginManager(packageStore: PluginPackageStore(
            rootDirectory: root, userDefaults: defaults, hostVersion: "1.0.0"
        ))
        let host = PluginHost(
            plugins: [], dynamicPluginManager: dynamicManager,
            pluginCatalogManager: PluginCatalogManager(
                catalogProvider: provider, packageResolver: PluginPackageResolver(temporaryDirectory: root),
                dynamicPluginManager: dynamicManager, source: .production(source)
            ),
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(), loadDynamicPluginsOnInit: false
        )
        defer { host.deactivateAllPlugins() }
        let target = MarketplacePluginDetailTarget(pluginID: "catalog-tool", providerID: "catalog-tool", actionID: "show")
        let coordinator = SettingsNavigationCoordinator(pluginHost: host)
        let router = AppURLRouter(acceptedURLSchemes: ["mactools"], rightClickHandler: { _ in })
        let url = URL(string: "mactools://app/settings/plugins/marketplace/catalog-tool?provider=catalog-tool&action=show")!
        XCTAssertEqual(router.handle(url), .queued(.settings(.marketplaceDetail(target))))
        XCTAssertEqual(router.activate(
            presentationHandler: { _ in coordinator.navigate(to: .marketplaceDetail(target)) },
            isPluginConfigurationAvailable: { host.hasPluginSettings(pluginID: $0) },
            isMarketplaceDetailAvailable: { host.canPresentMarketplaceDetail(target: $0) }
        ), [.handled(.settings(.marketplaceDetail(target)))])
        XCTAssertEqual(coordinator.destination, .marketplaceDetail(target))
        XCTAssertEqual(detailState(host: host, target: target, didAttemptLoad: false), .loading)

        await host.refreshPluginCatalog()
        XCTAssertEqual(detailState(host: host, target: target), .catalogFailure(try XCTUnwrap(host.pluginCatalogStatus.errorMessage)))
        coordinator.reconcileCurrentDestinationAvailability()
        XCTAssertEqual(coordinator.destination, .marketplaceDetail(target))

        provider.error = nil
        await host.refreshPluginCatalog()
        guard case let .detail(presentation) = detailState(host: host, target: target) else {
            return XCTFail("The pending link should resolve against the loaded catalog")
        }
        XCTAssertEqual(presentation.highlightedAction, target.actionHighlight)
        XCTAssertTrue(host.canPresentMarketplaceDetail(target: target))
        let unknownAction = MarketplacePluginDetailTarget(pluginID: "catalog-tool", providerID: "catalog-tool", actionID: "unknown")
        XCTAssertFalse(host.canPresentMarketplaceDetail(target: unknownAction))
        XCTAssertEqual(detailState(host: host, target: unknownAction), .unavailable)
        XCTAssertFalse(host.hasPluginSettings(pluginID: target.pluginID))
        XCTAssertEqual(router.handle(URL(string: "mactools://app/settings/plugins/catalog-tool")!), .rejected(.unavailablePlugin("catalog-tool")))
    }

    func testInstalledDetailsRemainUsableOfflineAndMissingResolvedDetailsAreUnavailable() throws {
        let target = MarketplacePluginDetailTarget(pluginID: "installed-tool")
        let item = PluginManagementItem(
            id: target.pluginID, title: "Installed Tool", summary: nil, version: "1.0.0", state: .installed,
            packageURL: URL(fileURLWithPath: "/unused/Installed.mactoolsplugin"),
            requiresRestartToFullyUnload: false, releaseNotesURL: nil
        )
        var status = PluginCatalogStatus.unavailable
        status.errorMessage = "Offline"
        let state = MarketplacePluginDetailState(item: item, target: target, catalogStatus: status, didAttemptCatalogLoad: false)
        XCTAssertEqual(state, .detail(try XCTUnwrap(MarketplacePluginDetailPresentation(item: item, target: target))))
        status.lastUpdatedAt = .distantPast
        status.errorMessage = nil
        XCTAssertEqual(MarketplacePluginDetailState(
            item: nil, target: target, catalogStatus: status, didAttemptCatalogLoad: true
        ), .unavailable)
    }

    private func detailState(
        host: PluginHost,
        target: MarketplacePluginDetailTarget,
        didAttemptLoad: Bool = true
    ) -> MarketplacePluginDetailState {
        MarketplacePluginDetailState(
            item: host.pluginManagementItems.first { $0.id == target.pluginID }, target: target,
            catalogStatus: host.pluginCatalogStatus, didAttemptCatalogLoad: didAttemptLoad
        )
    }
}

@MainActor
private final class DetailCatalogProvider: PluginCatalogProviding {
    let snapshot: PluginCatalogSnapshot
    var error: Error?

    init(snapshot: PluginCatalogSnapshot) { self.snapshot = snapshot }

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        if let error { throw error }
        return snapshot
    }
}
