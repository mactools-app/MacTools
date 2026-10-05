import Combine
import Foundation
import MacToolsPluginKit

/// Persisted display preferences shared by the settings workspace and the
/// widget detail list. The host storage keeps values across launches; the
/// default stays off so the workspace opens on found entries only.
@MainActor
final class SystemDataDisplayPreferences: ObservableObject {
    static let showAllItemsKey = "showAllItems"

    @Published var showAllItems: Bool {
        didSet {
            guard isAttached, let storage else { return }
            storage.set(showAllItems, forKey: Self.showAllItemsKey)
        }
    }

    private var storage: PluginStorage?
    private var isAttached = false

    init() {
        self.showAllItems = false
    }

    /// Binds host storage at activation and reads the persisted value once;
    /// a missing key keeps the default (off) and is not written back.
    func attach(storage: PluginStorage) {
        self.storage = storage
        showAllItems = storage.bool(forKey: Self.showAllItemsKey)
        isAttached = true
    }
}
