import Combine
import Foundation
import MacToolsPluginKit

enum StarterPackStep: Hashable {
    case choose, review, results
}

enum StarterPack: String, CaseIterable, Identifiable {
    case everyday, windows, writing, meetings, displays, developer, maintenance

    var id: String { rawValue }
    private var definition: StarterPackCatalog.Pack { StarterPackCatalog.shared.packs.first { $0.id == rawValue }! }
    var title: String { definition.title.localized }
    var symbol: String { definition.symbol }
    var summary: String { definition.summary.localized }
    var permissionSummary: String { definition.permission.localized }
    var pluginIDs: [String] { definition.pluginIDs }
    var panelItems: [PluginPanelItemKey] { definition.panelItems.map { .init(pluginID: $0.pluginID, itemID: $0.itemID) } }

    static func title(for pluginID: String) -> String {
        StarterPackCatalog.shared.plugins[pluginID]?.title.localized ?? pluginID
    }

    static func symbol(for pluginID: String) -> String {
        StarterPackCatalog.shared.plugins[pluginID]?.symbol ?? "puzzlepiece.extension"
    }
}

/// The app and website consume this same bundled catalog. Plugin packages remain independently installable.
struct StarterPackCatalog: Decodable {
    struct Text: Decodable {
        let en: String
        let zh: String
        let zhHant: String
        let translations: [String: String]?
        var localized: String {
            let locale = PluginRuntimeLocalization.locale.identifier
            let language = locale.components(separatedBy: CharacterSet(charactersIn: "_-"))[0]
            if let translation = translations?[language] { return translation }
            guard locale.hasPrefix("zh") else { return en }
            return locale.contains("Hant") || locale.contains("TW") || locale.contains("HK") ? zhHant : zh
        }
    }
    struct Pack: Decodable {
        struct PanelItem: Decodable { let pluginID: String; let itemID: String }
        let id: String
        let symbol: String
        let title: Text
        let summary: Text
        let permission: Text
        let pluginIDs: [String]
        let panelItems: [PanelItem]
    }
    struct Plugin: Decodable { let title: Text; let symbol: String; let permissionIDs: [String] }
    let packs: [Pack]
    let plugins: [String: Plugin]

    static let shared: Self = {
        guard let url = Bundle.main.url(forResource: "StarterPacks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data),
              catalog.packs.map(\.id) == StarterPack.allCases.map(\.rawValue)
        else { preconditionFailure("The bundled starter pack catalog is missing or invalid") }
        return catalog
    }()
}

struct StarterPackDraft {
    var selectedPluginIDs: Set<String>
    var addToPanel = true
    var panelID = MenuBarPanelDefinition.componentsID
    var seedGrid = false
    var assignShortcut = false
}

enum StarterPackGridState: Equatable {
    case empty, occupied, unavailable
}

struct StarterPackGridPreviewItem: Identifiable {
    var id: Int { slot }
    let slot: Int
    let title: String
    let symbol: String
}

/// Dependencies are closures so batch outcomes can be checked without downloads or system actions.
@MainActor
struct StarterPackServices {
    var installedIDs: () -> Set<String>
    var isUsable: (String) -> Bool
    var isCatalogReady: () -> Bool
    var install: (String) async throws -> Void
    var layout: () -> MenuBarPanelConfiguration
    var addPlacement: (PluginPanelItemKey, String) -> Bool
    var gridState: () -> StarterPackGridState
    var seedGrid: ([ActionReference]) -> Bool
    var hasGridShortcut: () -> Bool
    var assignGridShortcut: () -> String?
    var readinessMessage: (String) -> String = { _ in StarterPackError.notReady.localizedDescription }
}

struct StarterPackResult: Identifiable {
    enum Outcome: Equatable {
        case ready, installed, failed(String), skipped
    }
    let id: String
    var outcome: Outcome
}

@MainActor
final class StarterPackController: ObservableObject {
    static let onboardingKey = "app.starterPacks.onboardingComplete.v1"
    @Published private(set) var selectedPacks: Set<StarterPack>
    @Published private(set) var draft: StarterPackDraft
    @Published private(set) var needsOnboarding: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var stopRequested = false
    @Published private(set) var results: [StarterPackResult] = []
    @Published private(set) var setupMessages: [String] = []
    @Published private(set) var currentPluginID: String?
    @Published private(set) var appliedPacks: Set<StarterPack> = []
    private var appliedDraft: StarterPackDraft?
    private var excludedPluginIDs: Set<String> = []
    private var hasEditedSelection = false
    private(set) var resultPanelID = MenuBarPanelDefinition.componentsID
    @Published var showsProgress = false
    private let defaults: UserDefaults
    private let services: StarterPackServices
    private var installationTask: Task<Void, Never>?

    init(defaults: UserDefaults, hasExistingSetup: Bool, services: StarterPackServices) {
        self.defaults = defaults
        self.services = services
        let onboarding = !defaults.bool(forKey: Self.onboardingKey) && !hasExistingSetup
        needsOnboarding = onboarding
        selectedPacks = onboarding ? [.everyday] : []
        draft = StarterPackDraft(selectedPluginIDs: onboarding ? Set(StarterPack.everyday.pluginIDs) : [])
        draft.addToPanel = onboarding
        if hasExistingSetup { defaults.set(true, forKey: Self.onboardingKey) }
    }

    static func hasExistingPreferences(in defaults: UserDefaults) -> Bool {
        let prefixes = ["plugin.", "shortcut.", "menuBar.", "automation.", "actionShortcut."]
        return defaults.dictionaryRepresentation().keys.contains { key in
            prefixes.contains { key.hasPrefix($0) }
                || key == AppLanguagePreference.userDefaultsKey
                || key == "app.appearancePreference"
        }
    }

    var candidateIDs: [String] {
        var seen: Set<String> = []
        return StarterPack.allCases.filter { selectedPacks.contains($0) }.flatMap(\.pluginIDs).filter { seen.insert($0).inserted }
    }
    var selectedIDs: [String] { candidateIDs.filter { draft.selectedPluginIDs.contains($0) } }
    var permissionIDs: [String] {
        Set(selectedIDs.flatMap { StarterPackCatalog.shared.plugins[$0]?.permissionIDs ?? [] }).sorted()
    }
    var didApplyPanelLayout: Bool { appliedDraft?.addToPanel == true }
    var missingIDs: [String] { selectedIDs.filter { !services.installedIDs().contains($0) } }
    var needsCatalogLoad: Bool { !missingIDs.isEmpty && !services.isCatalogReady() }
    var gridState: StarterPackGridState { services.gridState() }
    var hasGridShortcut: Bool { services.hasGridShortcut() }
    var hasResults: Bool { !results.isEmpty }
    var installedCount: Int { results.filter { $0.outcome == .installed || $0.outcome == .ready }.count }
    var failedCount: Int { results.filter { if case .failed = $0.outcome { true } else { false } }.count }
    var wasStopped: Bool { !isRunning && stopRequested && results.contains { $0.outcome == .skipped } }

    func installedCount(in pack: StarterPack) -> Int {
        pack.pluginIDs.filter { services.installedIDs().contains($0) }.count
    }

    func finishOnboarding() {
        needsOnboarding = false
        defaults.set(true, forKey: Self.onboardingKey)
    }

    func updateDraft(_ update: (inout StarterPackDraft) -> Void) {
        guard !isRunning else { return }
        var value = draft
        update(&value)
        if value.selectedPluginIDs != draft.selectedPluginIDs { hasEditedSelection = true }
        value.selectedPluginIDs.formIntersection(candidateIDs)
        excludedPluginIDs.formUnion(Set(candidateIDs).subtracting(value.selectedPluginIDs))
        excludedPluginIDs.subtract(value.selectedPluginIDs)
        draft = value
    }

    func reviewSelection() { hasEditedSelection = true }

    func selectPack(_ pack: StarterPack, isSelected: Bool) {
        guard !isRunning else { return }
        hasEditedSelection = true
        if isSelected { selectedPacks.insert(pack) } else { selectedPacks.remove(pack) }
        draft.selectedPluginIDs = Set(candidateIDs).subtracting(excludedPluginIDs)
    }

    func selectAllPacks() {
        guard !isRunning else { return }
        hasEditedSelection = true
        selectedPacks = Set(StarterPack.allCases)
        draft.selectedPluginIDs = Set(candidateIDs).subtracting(excludedPluginIDs)
    }

    func clearSelection() {
        guard !isRunning else { return }
        hasEditedSelection = true
        selectedPacks = []
        excludedPluginIDs = []
        draft.selectedPluginIDs = []
    }

    func includePackFromLink(_ pack: StarterPack) {
        guard !isRunning else { return }
        if !hasEditedSelection { selectedPacks = [] }
        selectPack(pack, isSelected: true)
    }

    func restoreAppliedSelection() {
        guard !isRunning, let appliedDraft else { return }
        selectedPacks = appliedPacks
        draft = appliedDraft
        excludedPluginIDs = Set(candidateIDs).subtracting(draft.selectedPluginIDs)
        hasEditedSelection = true
    }

    var recommendedPanelItems: [PluginPanelItemKey] {
        var seen: Set<PluginPanelItemKey> = []
        return StarterPack.allCases.filter { selectedPacks.contains($0) }.flatMap(\.panelItems)
            .filter { draft.selectedPluginIDs.contains($0.pluginID) && seen.insert($0).inserted }
    }

    var pendingPanelItems: [PluginPanelItemKey] {
        guard draft.addToPanel else { return [] }
        let placed = Set(services.layout().placementsByPanelID.values.flatMap { $0 }.map(\.item))
        return recommendedPanelItems.filter { !placed.contains($0) }
    }

    var canSeedGrid: Bool {
        draft.selectedPluginIDs.contains("action-grid")
            && draft.selectedPluginIDs.contains("window-layouts") && gridState == .empty
    }

    var hasChanges: Bool {
        !selectedIDs.isEmpty && (!missingIDs.isEmpty || !pendingPanelItems.isEmpty
            || (canSeedGrid && draft.seedGrid)
            || (selectedIDs.contains("action-grid") && draft.assignShortcut && !hasGridShortcut))
    }

    var canApply: Bool { !isRunning && hasChanges && !needsCatalogLoad }

    @discardableResult
    func apply() -> Bool {
        guard canApply else { return false }
        let reviewedDraft = draft
        let panelItems = recommendedPanelItems
        let selected = selectedIDs
        appliedPacks = selectedPacks
        appliedDraft = reviewedDraft
        resultPanelID = reviewedDraft.panelID
        finishOnboarding()
        isRunning = true
        stopRequested = false
        showsProgress = true
        setupMessages = []
        results = selected.map { .init(id: $0, outcome: .skipped) }
        installationTask = Task { [self] in
            for id in selected {
                guard !stopRequested else { break }
                currentPluginID = id
                do {
                    let alreadyInstalled = services.installedIDs().contains(id)
                    if !alreadyInstalled { try await services.install(id) }
                    guard services.installedIDs().contains(id), services.isUsable(id) else {
                        throw StarterPackError.unavailable(services.readinessMessage(id))
                    }
                    setResult(id, alreadyInstalled ? .ready : .installed)
                    if reviewedDraft.addToPanel,
                       let item = panelItems.first(where: { $0.pluginID == id }) {
                        let layout = services.layout()
                        let placed = layout.placementsByPanelID.values.flatMap { $0 }.contains { $0.item == item }
                        if !placed, !services.addPlacement(item, reviewedDraft.panelID) {
                            setupMessages.append(FeatureL10n.string("未能添加到面板，请在面板编辑器中添加。"))
                        }
                    }
                } catch {
                    setResult(id, .failed(error.localizedDescription))
                }
            }
            if reviewedDraft.seedGrid,
               selected.contains("action-grid"), selected.contains("window-layouts"),
               succeeded("action-grid"), succeeded("window-layouts"), services.gridState() == .empty {
                let references = ["left-half", "right-half", "maximize"].map {
                    ActionReference(key: .init(providerID: "window-layouts", actionID: $0))
                }
                if !services.seedGrid(references) {
                    setupMessages.append(FeatureL10n.string("未能设置操作网格，请打开插件设置。"))
                }
            }
            if selected.contains("action-grid"), succeeded("action-grid"),
               reviewedDraft.assignShortcut, !services.hasGridShortcut(),
               let error = services.assignGridShortcut() { setupMessages.append(error) }
            currentPluginID = nil
            isRunning = false
            installationTask = nil
        }
        return true
    }

    func stopAfterCurrentPlugin() { stopRequested = true }

    private func setResult(_ id: String, _ outcome: StarterPackResult.Outcome) {
        if let index = results.firstIndex(where: { $0.id == id }) { results[index].outcome = outcome }
    }

    private func succeeded(_ id: String) -> Bool {
        results.contains { $0.id == id && ($0.outcome == .ready || $0.outcome == .installed) }
    }

    func waitForInstallation() async { await installationTask?.value }
}

enum StarterPackError: LocalizedError {
    case notReady
    case busy
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .notReady:
            FeatureL10n.string("插件尚未就绪。请打开详情查看兼容性、加载状态或重启要求。")
        case .busy:
            FeatureL10n.string("另一项插件操作正在进行，请完成后重试。")
        case let .unavailable(message):
            message
        }
    }
}

/// Uses Action Grid's portable preference format; restoration stays with the plugin.
struct StarterPackGridPreferences: Encodable {
    struct Entry: Encodable {
        let id = UUID()
        let reference: ActionReference
        let slot: Int
    }
    let formatVersion = 3
    let entries: [Entry]

    init(references: [ActionReference]) {
        entries = references.enumerated().map { Entry(reference: $0.element, slot: $0.offset) }
    }
}
