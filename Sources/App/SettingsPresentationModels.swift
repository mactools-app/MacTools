import Combine
import SwiftUI

/// Navigation depends on page metadata, not on live controls or custom view factories.
struct SettingsPluginNavigationItem: Identifiable, Equatable {
    let id: String
    let title: String
    let iconName: String
    let iconTint: Color
    let installedAt: Date?

    init(_ item: PluginSettingsPageItem) {
        id = item.id
        title = item.title
        iconName = item.iconName
        iconTint = item.iconTint
        installedAt = item.installedAt
    }
}

@MainActor
final class SettingsNavigationPresentationModel: ObservableObject {
    @Published private(set) var configurationItems: [SettingsPluginNavigationItem] = []
    @Published private(set) var marketplaceItems: [PluginManagementItem] = []
    private var subscriptions: Set<AnyCancellable> = []

    init(host: PluginHost) {
        host.$pluginSettingsItems
            .map { $0.map(SettingsPluginNavigationItem.init) }
            .removeDuplicates()
            .sink { [weak self] in self?.configurationItems = $0 }
            .store(in: &subscriptions)
        host.$pluginManagementItems
            .removeDuplicates()
            .sink { [weak self] in self?.marketplaceItems = $0 }
            .store(in: &subscriptions)
    }
}

@MainActor
final class PluginMarketplacePresentationModel: ObservableObject {
    @Published private(set) var items: [PluginManagementItem] = []
    @Published private(set) var configurationPluginIDs: Set<String> = []
    @Published private(set) var catalogStatus: PluginCatalogStatus = .unavailable
    @Published private(set) var automaticUpdateStatus: PluginAutomaticUpdateStatus = .idle
    @Published private(set) var hasActiveMarketplaceOperation = false
    private var subscriptions: Set<AnyCancellable> = []

    init(host: PluginHost) {
        host.$pluginManagementItems
            .removeDuplicates()
            .sink { [weak self] in self?.items = $0 }
            .store(in: &subscriptions)
        host.$pluginSettingsItems
            .map { Set($0.map(\.pluginID)) }
            .removeDuplicates()
            .sink { [weak self] in self?.configurationPluginIDs = $0 }
            .store(in: &subscriptions)
        host.$pluginCatalogStatus
            .removeDuplicates()
            .sink { [weak self] in self?.catalogStatus = $0 }
            .store(in: &subscriptions)
        host.$automaticPluginUpdateStatus
            .removeDuplicates()
            .sink { [weak self] in self?.automaticUpdateStatus = $0 }
            .store(in: &subscriptions)
        host.$pluginMarketplaceOperations
            .map { $0.values.contains(where: \.isActive) }
            .removeDuplicates()
            .sink { [weak self] in self?.hasActiveMarketplaceOperation = $0 }
            .store(in: &subscriptions)
    }
}
