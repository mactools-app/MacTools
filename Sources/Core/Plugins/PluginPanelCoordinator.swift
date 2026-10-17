import SwiftUI
import MacToolsPluginKit

@MainActor
struct PanelCatalogItem: Identifiable {
    let key: PluginPanelItemKey
    let pluginTitle: String
    let metadata: PluginMetadata
    let definition: PluginPanelItem
    let supportsCompactSwitch: Bool
    private let sourceDefaultDescription: String

    init(key: PluginPanelItemKey, pluginTitle: String, metadata: PluginMetadata,
         definition: PluginPanelItem, sourceDefaultDescription: String? = nil,
         supportsCompactSwitch: Bool = false) {
        self.supportsCompactSwitch = supportsCompactSwitch
        self.key = key
        self.pluginTitle = pluginTitle
        self.metadata = metadata
        self.definition = definition
        self.sourceDefaultDescription = sourceDefaultDescription ?? metadata.defaultDescription
    }

    nonisolated var id: String { key.id }
    var kind: PluginPanelItemKind { definition.kind }
    var title: String { definition.title ?? metadata.title }
    var description: String { definition.description ?? metadata.defaultDescription }
    var iconName: String { definition.systemImage ?? metadata.iconName }
    var iconTint: Color { definition.iconTint ?? metadata.iconTint }
    var isAvailable: Bool {
        switch definition.content {
        case .row(let row): row.state.isAvailable
        case .widget(let widget): widget.state.isAvailable
        }
    }

    func displayDescription(subtitle: String, errorMessage: String?) -> String {
        if let errorMessage {
            return errorMessage.isEmpty ? description : errorMessage
        }
        // Plugin metadata may retain the language used at initialization. Only
        // replace its default text; dynamic subtitles and errors are plugin-owned.
        return subtitle.isEmpty || subtitle == sourceDefaultDescription ? description : subtitle
    }
}

@MainActor
struct ResolvedPanelPlacement: Identifiable {
    let entry: MenuBarPanelEntry
    let item: PanelCatalogItem
    nonisolated var id: String { entry.id }
}

/// Owns panel-only state; settings, permissions, and business refresh stay in the host/plugin.
@MainActor
final class PluginPanelCoordinator {
    enum CatalogError: Error, Equatable {
        case tooManyItems
        case invalidID(String)
        case duplicateID(String)
        case undeclaredKind(PluginPanelItemKind)
        case changedKind(String)
    }

    private final class WidgetSession {
        var revision: UInt64 = 0
        var content: AnyView?
        var measuredSpan: PluginPanelWidgetSpan?
        var dismiss: () -> Void = {}
        var presentDetail: (String) -> Void = { _ in }
    }

    private(set) var catalog: [PanelCatalogItem] = []
    private var itemsByKey: [PluginPanelItemKey: PanelCatalogItem] = [:]
    private var keysByPluginID: [String: [PluginPanelItemKey]] = [:]
    private var knownKinds: [PluginPanelItemKey: PluginPanelItemKind] = [:]
    private var revisions: [String: UInt64] = [:]
    private var placementsByID: [String: MenuBarPanelEntry] = [:]
    private var snapshots: [String: [ResolvedPanelPlacement]] = [:]
    private var widgetSessions: [String: WidgetSession] = [:]
    private var expandedPlacements: Set<String> = []
    private var navigationSelections: [String: [String: String]] = [:]
    private var deliveredVisibility: [PluginPanelItemKey: (Bool) -> Void] = [:]
    private var desiredVisibleItems: Set<PluginPanelItemKey> = []
    private var isSynchronizingVisibility = false
    private var layoutChangeTask: Task<Void, Never>?
    var onLayoutChange: () -> Void = {}
    var invoke: (String, () -> Void) -> Void = { _, action in action() }

    deinit { layoutChangeTask?.cancel() }

    func update(pluginID: String, metadata: PluginMetadata, definitions: [PluginPanelItem],
                allowedKinds: Set<PluginPanelItemKind>, sourceDefaultDescription: String? = nil,
                compactSwitchItemIDs: Set<String> = []) throws {
        guard definitions.count <= 256 else { throw CatalogError.tooManyItems }
        var seen: Set<String> = []
        for item in definitions {
            guard !item.id.isEmpty, item.id.utf8.count <= 128,
                  item.id.utf8.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                          || byte == 45 || byte == 46 || byte == 95
                  }) else { throw CatalogError.invalidID(item.id) }
            guard seen.insert(item.id).inserted else { throw CatalogError.duplicateID(item.id) }
            guard allowedKinds.contains(item.kind) else { throw CatalogError.undeclaredKind(item.kind) }
            let key = PluginPanelItemKey(pluginID: pluginID, itemID: item.id)
            if let previous = knownKinds[key], previous != item.kind { throw CatalogError.changedKind(item.id) }
        }
        let items = definitions.map {
            PanelCatalogItem(key: PluginPanelItemKey(pluginID: pluginID, itemID: $0.id),
                             pluginTitle: metadata.title, metadata: metadata, definition: $0,
                             sourceDefaultDescription: sourceDefaultDescription,
                             supportsCompactSwitch: compactSwitchItemIDs.contains($0.id))
        }
        for key in keysByPluginID[pluginID, default: []] { itemsByKey.removeValue(forKey: key) }
        keysByPluginID[pluginID] = items.map(\.key)
        for item in items {
            itemsByKey[item.key] = item
            knownKinds[item.key] = item.kind
        }
        revisions[pluginID, default: 0] &+= 1
    }

    func synchronize(configuration: MenuBarPanelConfiguration, pluginOrder: [String], visiblePanelID: String?) {
        let previouslyExpandedKeys = Set(expandedPlacements.compactMap { placementsByID[$0]?.key })
        let active = Set(pluginOrder)
        for pluginID in Array(keysByPluginID.keys) where !active.contains(pluginID) { removePlugin(pluginID) }
        catalog = pluginOrder.flatMap { keysByPluginID[$0, default: []].compactMap { itemsByKey[$0] } }
        snapshots.removeAll(keepingCapacity: true)
        placementsByID.removeAll(keepingCapacity: true)
        var retainedRowPresentationIDs: Set<String> = []
        for panel in configuration.panels {
            snapshots[panel.id] = configuration.placementsByPanelID[panel.id, default: []].compactMap { placement in
                guard let item = itemsByKey[placement.item] else { return nil }
                let entry = MenuBarPanelEntry(placement: placement, kind: item.kind)
                placementsByID[entry.id] = entry
                guard item.isAvailable else { return nil }
                // Keep disabled detail content visible, but discard presentation
                // state when the row has nothing available to expand.
                if case let .row(row) = item.definition.content,
                   row.state.isEnabled || row.state.detail != nil {
                    retainedRowPresentationIDs.insert(entry.id)
                }
                return ResolvedPanelPlacement(entry: entry, item: item)
            }
        }
        let retainedIDs = Set(placementsByID.keys)
        widgetSessions = widgetSessions.filter { retainedIDs.contains($0.key) }
        expandedPlacements.formIntersection(retainedRowPresentationIDs)
        navigationSelections = navigationSelections.filter { retainedRowPresentationIDs.contains($0.key) }
        setVisiblePanel(visiblePanelID)
        let expandedKeys = Set(expandedPlacements.compactMap { placementsByID[$0]?.key })
        // Retiring or invalidating the last expanded copy must also release
        // plugin-side detail work, without duplicating notifications for copies.
        for key in previouslyExpandedKeys.subtracting(expandedKeys) {
            guard let item = itemsByKey[key], case let .row(row) = item.definition.content else { continue }
            invoke(key.pluginID) { row.action(.setDisclosureExpanded(false)) }
        }
    }

    func snapshot(in panelID: String) -> [ResolvedPanelPlacement] { snapshots[panelID] ?? [] }
    func item(for key: PluginPanelItemKey) -> PanelCatalogItem? { itemsByKey[key] }
    func hasSnapshot(for pluginID: String) -> Bool { revisions[pluginID] != nil }

    func initialPlacements(pluginOrder: [String]) -> [(key: PluginPanelItemKey, initialPlacement: PluginPanelInitialPlacement?)] {
        pluginOrder.flatMap { pluginID in
            keysByPluginID[pluginID, default: []].compactMap { key in
                itemsByKey[key].map { (key: key, initialPlacement: $0.definition.initialPlacement) }
            }
        }
    }
    func entry(for presentationID: String) -> MenuBarPanelEntry? { placementsByID[presentationID] }

    func item(for presentationID: String) -> PanelCatalogItem? {
        if let entry = placementsByID[presentationID] { return itemsByKey[entry.key] }
        return catalog.first { $0.id == presentationID }
    }

    func setVisiblePanel(_ panelID: String?) {
        desiredVisibleItems = Set(panelID.map { snapshot(in: $0).map(\.entry.key) } ?? [])
        synchronizeVisibility()
    }

    private func synchronizeVisibility() {
        guard !isSynchronizingVisibility else { return }
        isSynchronizingVisibility = true
        defer { isSynchronizingVisibility = false }
        // Update delivered state before invoking callbacks, then re-evaluate after
        // every callback: plugins can synchronously close panels or remove items.
        while true {
            let delivered = Set(deliveredVisibility.keys)
            if let key = desiredVisibleItems.subtracting(delivered).sorted(by: { $0.id < $1.id }).first {
                let handler = itemsByKey[key]?.definition.visibilityHandler ?? { _ in }
                deliveredVisibility[key] = handler
                invoke(key.pluginID) { handler(true) }
            } else if let key = delivered.subtracting(desiredVisibleItems).sorted(by: { $0.id < $1.id }).first,
                      let handler = deliveredVisibility.removeValue(forKey: key) {
                invoke(key.pluginID) { handler(false) }
            } else { break }
        }
    }

    func removePlugin(_ pluginID: String) {
        desiredVisibleItems = desiredVisibleItems.filter { $0.pluginID != pluginID }
        synchronizeVisibility()
        for key in keysByPluginID.removeValue(forKey: pluginID) ?? [] { itemsByKey.removeValue(forKey: key) }
        revisions.removeValue(forKey: pluginID)
        knownKinds = knownKinds.filter { $0.key.pluginID != pluginID }
        widgetSessions = widgetSessions.filter { placementsByID[$0.key]?.pluginID != pluginID }
    }

    func isExpanded(_ id: String) -> Bool { expandedPlacements.contains(id) }
    func hasExpandedPlacement(for id: String) -> Bool {
        guard let key = placementsByID[id]?.key else { return false }
        return expandedPlacements.contains { placementsByID[$0]?.key == key }
    }
    func setExpanded(_ expanded: Bool, id: String) {
        guard placementsByID[id]?.kind == .row else { return }
        if expanded { expandedPlacements.insert(id) } else { expandedPlacements.remove(id) }
        if !expanded { navigationSelections.removeValue(forKey: id) }
    }

    func setNavigationSelection(_ optionID: String?, controlID: String, id: String) {
        guard placementsByID[id]?.kind == .row else { return }
        navigationSelections[id, default: [:]][controlID] = optionID
    }

    func widgetView(for id: String, dismiss: @escaping () -> Void,
                    presentDetail: @escaping (String) -> Void) -> AnyView? {
        guard let entry = placementsByID[id], let item = itemsByKey[entry.key],
              case let .widget(widget) = item.definition.content else { return nil }
        let session = widgetSessions[id] ?? WidgetSession()
        widgetSessions[id] = session
        session.dismiss = dismiss
        session.presentDetail = presentDetail
        let revision = revisions[entry.pluginID, default: 0]
        if session.content == nil || session.revision != revision {
            let context = PluginPanelWidgetContext(pluginID: entry.pluginID, itemID: entry.itemID,
                placementID: entry.placement.id, dismiss: { [weak session] in session?.dismiss() },
                presentDetail: { [weak session] in session?.presentDetail($0) },
                reportContentHeight: { [weak self, weak session, span = widget.descriptor.span] height in
                    guard let self, let session, self.widgetSessions[id] === session else { return }
                    self.updateWidgetHeight(height, declaredSpan: span, id: id, session: session)
                })
            invoke(entry.pluginID) { session.content = widget.makeView(context) }
            session.revision = revision
        }
        return session.content
    }

    private func updateWidgetHeight(_ height: CGFloat, declaredSpan: PluginPanelWidgetSpan,
                                    id: String, session: WidgetSession) {
        guard height.isFinite, height > 0,
              let item = item(for: id), item.isAvailable,
              case let .widget(widget) = item.definition.content,
              widget.descriptor.span.width == declaredSpan.width,
              widget.descriptor.span.grid == declaredSpan.grid,
              let heightSpan = Int(exactly: ceil(height / PluginPanelWidgetLayoutMetrics.default.cellHeight)),
              let span = PluginPanelWidgetSpan(width: declaredSpan.width, height: heightSpan,
                                              grid: declaredSpan.grid) else { return }
        let previous = session.measuredSpan ?? widget.descriptor.span
        session.measuredSpan = span
        guard span != previous, layoutChangeTask == nil else { return }
        // Coalesce measurements outside SwiftUI's layout pass. Size changes do
        // not reread plugin definitions, restart services, or recreate content.
        layoutChangeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.layoutChangeTask = nil
            self.onLayoutChange()
        }
    }

    func clearWidgetViews() { widgetSessions.removeAll() }
    func isWidgetViewCached(_ id: String) -> Bool { widgetSessions[id]?.content != nil }

    func rowSnapshot(_ item: PanelCatalogItem, id: String? = nil) -> PluginPanelRowSnapshot? {
        guard case let .row(row) = item.definition.content else { return nil }
        let state = row.state
        let descriptor = row.descriptor
        let description = item.displayDescription(subtitle: state.subtitle, errorMessage: state.errorMessage)
        var buttonTitle: String?
        if descriptor.controlStyle == .button {
            invoke(item.key.pluginID) { buttonTitle = descriptor.buttonTitle }
        }
        return PluginPanelRowSnapshot(id: id ?? item.id, title: item.title, iconName: item.iconName,
            iconTint: item.iconTint, controlStyle: descriptor.controlStyle,
            menuActionBehavior: descriptor.menuActionBehavior,
            description: description, helpText: description,
            descriptionTone: state.errorMessage == nil ? .secondary : .error,
            isOn: state.isOn, isExpanded: id.map(isExpanded) ?? false, isEnabled: state.isEnabled,
            detail: state.detail.map { detailSnapshot($0, id: id) },
            buttonActionID: descriptor.controlStyle == .button ? "execute" : nil,
            buttonTitle: buttonTitle, pluginID: item.key.pluginID,
            supportsCompactSwitch: item.supportsCompactSwitch && descriptor.controlStyle == .switch,
            usesCompactPresentation: item.supportsCompactSwitch && descriptor.controlStyle == .switch
                && id.flatMap { placementsByID[$0]?.placement.presentation } == MenuBarPanelItemPresentation.compactSwitch
                && state.detail == nil && state.indicator == nil && state.compactIndicator == nil
                && state.errorMessage == nil && state.isEnabled,
            width: id.flatMap { placementsByID[$0]?.placement.width })
    }

    private func detailSnapshot(_ detail: PluginPanelDetail, id: String?) -> PluginPanelDetail {
        let selections = id.flatMap { navigationSelections[$0] } ?? [:]
        func controls(_ source: [PluginPanelControl]) -> [PluginPanelControl] {
            source.map { control in
                guard control.kind == .navigationList else { return control }
                let selection = selections[control.id].flatMap { id in
                    control.options.contains { $0.id == id } ? id : nil
                }
                return control.selectingNavigationOption(selection)
            }
        }
        let secondary = detail.navigationSecondaryPanels.isEmpty ? detail.secondaryPanel :
            detail.navigationSecondaryPanels.first { selections[$0.controlID] == $0.optionID }?.panel
        return PluginPanelDetail(primaryControls: controls(detail.primaryControls),
            secondaryPanel: secondary.map { .init(title: $0.title, controls: controls($0.controls)) },
            navigationSecondaryPanels: detail.navigationSecondaryPanels.map {
                .init(controlID: $0.controlID, optionID: $0.optionID,
                      panel: .init(title: $0.panel.title, controls: controls($0.panel.controls)))
            })
    }

    func widgetSnapshot(_ item: PanelCatalogItem, id: String? = nil) -> PluginPanelWidgetSnapshot? {
        guard case let .widget(widget) = item.definition.content else { return nil }
        let state = widget.state
        let description = item.displayDescription(subtitle: state.subtitle, errorMessage: state.errorMessage)
        let measured = id.flatMap { widgetSessions[$0]?.measuredSpan }
        let span = measured.flatMap {
            $0.width == widget.descriptor.span.width && $0.grid == widget.descriptor.span.grid ? $0 : nil
        }
            ?? widget.descriptor.span
        return PluginPanelWidgetSnapshot(id: id ?? item.id, title: item.title, iconName: item.iconName,
            iconTint: item.iconTint, description: description, helpText: description,
            descriptionTone: state.errorMessage == nil ? .secondary : .error,
            span: span, isActive: state.isActive, isEnabled: state.isEnabled,
            pluginID: item.key.pluginID)
    }
}
