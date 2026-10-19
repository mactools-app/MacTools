import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginPanelCoordinatorTests: XCTestCase {
    private func metadata(_ id: String = "example") -> PluginMetadata {
        PluginMetadata(id: id, title: id, iconName: "star", iconTint: .blue, order: 0, defaultDescription: "Example")
    }

    private func row(_ id: String, visible: Bool = true, action: @escaping (PluginPanelAction) -> Void = { _ in }) -> PluginPanelItem {
        .row(id: id, initialPlacement: .featurePanel,
             descriptor: PluginPanelRowDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented),
             state: PluginPanelRowState(subtitle: id, isOn: false, isEnabled: true,
                                        isAvailable: visible, detail: nil, errorMessage: nil), action: action)
    }

    private func widget(_ id: String, grid: PluginPanelWidgetGrid = .standard,
                        make: @escaping (PluginPanelWidgetContext) -> AnyView) -> PluginPanelItem {
        .widget(id: id, initialPlacement: .dashboard,
                descriptor: PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(width: 2, height: 8, grid: grid)!),
                state: PluginPanelWidgetState(subtitle: id, isActive: false, isEnabled: true, isAvailable: true, errorMessage: nil),
                content: make)
    }

    func testCompactSwitchRequiresOptInAndPreservesPreferenceDuringFallback() throws {
        let coordinator = PluginPanelCoordinator()
        let placement = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "control"),
                                              presentation: "compact-switch")
        var configuration = MenuBarPanelConfiguration()
        configuration.placementsByPanelID["features"] = [placement]
        func snapshot() throws -> PluginPanelRowSnapshot {
            coordinator.synchronize(configuration: configuration, pluginOrder: ["example"], visiblePanelID: nil)
            let resolved = try XCTUnwrap(coordinator.snapshot(in: "features").first)
            return try XCTUnwrap(coordinator.rowSnapshot(resolved.item, id: resolved.id))
        }
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [row("control")], allowedKinds: [.row])
        XCTAssertFalse(try snapshot().usesCompactPresentation)
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [row("control")],
                               allowedKinds: [.row], compactSwitchItemIDs: ["control"])
        XCTAssertTrue(try snapshot().usesCompactPresentation)
        let error = PluginPanelItem.row(id: "control", descriptor: .init(controlStyle: .switch, menuActionBehavior: .keepPresented),
            state: .init(subtitle: "Permission required", isOn: false, isEnabled: false, isAvailable: true,
                         detail: nil, errorMessage: "Permission required"), action: { _ in })
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [error],
                               allowedKinds: [.row], compactSwitchItemIDs: ["control"])
        XCTAssertFalse(try snapshot().usesCompactPresentation)
        XCTAssertTrue(try snapshot().supportsCompactSwitch)
        XCTAssertEqual(configuration.placementsByPanelID["features"]?.first?.presentation, "compact-switch")
    }

    func testMultipleRowsAndWidgetsAreResolvedByItemAndPlacement() throws {
        let coordinator = PluginPanelCoordinator()
        let definitions = [row("first"), row("second"), widget("chart") { _ in AnyView(EmptyView()) }]
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: definitions, allowedKinds: [.row, .widget])
        let first = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "first"))
        let second = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "second"))
        let copy = MenuBarPanelPlacement(item: first.item)
        var configuration = MenuBarPanelConfiguration()
        configuration.placementsByPanelID["features"] = [first, second, copy]
        coordinator.synchronize(configuration: configuration, pluginOrder: ["example"], visiblePanelID: nil)
        XCTAssertEqual(coordinator.catalog.map(\.key.itemID), ["first", "second", "chart"])
        XCTAssertEqual(coordinator.snapshot(in: "features").map(\.entry.placement), [first, second, copy])
        coordinator.setExpanded(true, id: first.id.uuidString.lowercased())
        XCTAssertFalse(coordinator.isExpanded(copy.id.uuidString.lowercased()))
        XCTAssertTrue(coordinator.hasExpandedPlacement(for: copy.id.uuidString.lowercased()))
    }

    func testNavigationSelectionIsScopedToEachPlacement() throws {
        let coordinator = PluginPanelCoordinator()
        let control = PluginPanelControl(id: "navigate", kind: .navigationList,
            options: [.init(id: "one", title: "One"), .init(id: "two", title: "Two")],
            selectedOptionID: "one", dateValue: nil, minimumDate: nil, displayedComponents: nil,
            datePickerStyle: nil, sectionTitle: nil, isEnabled: true)
        let definition = PluginPanelItem.row(id: "control", descriptor: .init(controlStyle: .disclosure,
            menuActionBehavior: .keepPresented), state: .init(subtitle: "", isOn: false, isEnabled: true,
            isAvailable: true, detail: .init(controls: [control]), errorMessage: nil), action: { _ in })
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [definition], allowedKinds: [.row])
        let first = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "control"))
        let second = MenuBarPanelPlacement(item: first.item)
        var layout = MenuBarPanelConfiguration()
        layout.placementsByPanelID["features"] = [first, second]
        coordinator.synchronize(configuration: layout, pluginOrder: ["example"], visiblePanelID: nil)
        let entries = coordinator.snapshot(in: "features")
        coordinator.setNavigationSelection("two", controlID: "navigate", id: entries[0].id)
        XCTAssertEqual(coordinator.rowSnapshot(entries[0].item, id: entries[0].id)?.detail?.controls.first?.selectedOptionID, "two")
        XCTAssertNil(coordinator.rowSnapshot(entries[1].item, id: entries[1].id)?.detail?.controls.first?.selectedOptionID)
        coordinator.setExpanded(false, id: entries[0].id)
        XCTAssertNil(coordinator.rowSnapshot(entries[0].item, id: entries[0].id)?.detail?.controls.first?.selectedOptionID)
    }

    func testRemovingTheLastExpandedCopyCollapsesPluginDetailWork() throws {
        let coordinator = PluginPanelCoordinator()
        var actions: [PluginPanelAction] = []
        try coordinator.update(pluginID: "example", metadata: metadata(),
            definitions: [row("control", action: { actions.append($0) })], allowedKinds: [.row])
        let first = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "control"))
        let copy = MenuBarPanelPlacement(item: first.item)
        var layout = MenuBarPanelConfiguration()
        layout.placementsByPanelID["features"] = [first, copy]
        coordinator.synchronize(configuration: layout, pluginOrder: ["example"], visiblePanelID: nil)
        for entry in coordinator.snapshot(in: "features") { coordinator.setExpanded(true, id: entry.id) }
        layout.placementsByPanelID["features"] = [copy]
        coordinator.synchronize(configuration: layout, pluginOrder: ["example"], visiblePanelID: nil)
        XCTAssertTrue(actions.isEmpty)
        layout.placementsByPanelID["features"] = []
        coordinator.synchronize(configuration: layout, pluginOrder: ["example"], visiblePanelID: nil)
        coordinator.synchronize(configuration: layout, pluginOrder: ["example"], visiblePanelID: nil)
        XCTAssertEqual(actions, [.setDisclosureExpanded(false)])
    }

    func testValidationRejectsAmbiguousDefinitionsBeforeReplacingCatalog() throws {
        let coordinator = PluginPanelCoordinator()
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [row("valid")], allowedKinds: [.row])
        for definitions in [[row("duplicate"), row("duplicate")], [row("bad:id")],
                            [widget("valid") { _ in AnyView(EmptyView()) }]] {
            XCTAssertThrowsError(try coordinator.update(pluginID: "example", metadata: metadata(),
                definitions: definitions, allowedKinds: [.row]))
        }
        XCTAssertNotNil(coordinator.item(for: PluginPanelItemKey(pluginID: "example", itemID: "valid")))
        try coordinator.update(pluginID: "other", metadata: metadata("other"), definitions: [row("valid")], allowedKinds: [.row])
        XCTAssertNotNil(coordinator.item(for: PluginPanelItemKey(pluginID: "other", itemID: "valid")))
    }

    func testVisibilityAggregatesCopiesAndDoesNotChurnAcrossPanelSwitches() throws {
        let coordinator = PluginPanelCoordinator()
        var events: [Bool] = []
        try coordinator.update(pluginID: "example", metadata: metadata(),
            definitions: [row("control").onVisibilityChange { events.append($0) }], allowedKinds: [.row])
        let first = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "control"))
        let second = MenuBarPanelPlacement(item: first.item)
        var configuration = MenuBarPanelConfiguration()
        configuration.placementsByPanelID = ["features": [first, second], "components": [MenuBarPanelPlacement(item: first.item)]]
        coordinator.synchronize(configuration: configuration, pluginOrder: ["example"], visiblePanelID: "features")
        coordinator.setVisiblePanel("components")
        XCTAssertEqual(events, [true])
        coordinator.setVisiblePanel(nil)
        coordinator.setVisiblePanel(nil)
        XCTAssertEqual(events, [true, false])
    }

    func testLifecycleCanClosePanelReentrantlyWithoutDuplicateDelivery() throws {
        let coordinator = PluginPanelCoordinator()
        var events: [Bool] = []
        let item = row("control").onVisibilityChange { visible in
            events.append(visible)
            if visible { coordinator.setVisiblePanel(nil) }
        }
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [item], allowedKinds: [.row])
        var configuration = MenuBarPanelConfiguration()
        configuration.placementsByPanelID["features"] = [.init(item: .init(pluginID: "example", itemID: "control"))]
        coordinator.synchronize(configuration: configuration, pluginOrder: ["example"], visiblePanelID: "features")
        XCTAssertEqual(events, [true, false])
    }

    func testWidgetFactoriesAreLazyAndCachesFollowOnlyTheirPluginRevision() throws {
        let coordinator = PluginPanelCoordinator()
        var contexts: [PluginPanelWidgetContext] = []
        let definition = widget("chart") { context in contexts.append(context); return AnyView(EmptyView()) }
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [definition], allowedKinds: [.widget])
        let first = MenuBarPanelPlacement(item: .init(pluginID: "example", itemID: "chart"))
        let copy = MenuBarPanelPlacement(item: first.item)
        var configuration = MenuBarPanelConfiguration()
        configuration.placementsByPanelID["components"] = [first, copy]
        coordinator.synchronize(configuration: configuration, pluginOrder: ["example"], visiblePanelID: nil)
        XCTAssertTrue(contexts.isEmpty)
        let id = first.id.uuidString.lowercased()
        var dismissed = 0
        _ = coordinator.widgetView(for: id, dismiss: { dismissed += 1 }, presentDetail: { _ in })
        _ = coordinator.widgetView(for: id, dismiss: { dismissed += 10 }, presentDetail: { _ in })
        XCTAssertEqual(contexts.count, 1)
        contexts[0].dismiss()
        XCTAssertEqual(dismissed, 10)
        _ = coordinator.widgetView(for: copy.id.uuidString.lowercased(), dismiss: {}, presentDetail: { _ in })
        XCTAssertEqual(contexts.map(\.placementID), [first.id, copy.id])
        try coordinator.update(pluginID: "other", metadata: metadata("other"), definitions: [row("control")], allowedKinds: [.row])
        _ = coordinator.widgetView(for: id, dismiss: {}, presentDetail: { _ in })
        XCTAssertEqual(contexts.count, 2)
        try coordinator.update(pluginID: "example", metadata: metadata(), definitions: [definition], allowedKinds: [.widget])
        _ = coordinator.widgetView(for: id, dismiss: {}, presentDetail: { _ in })
        XCTAssertEqual(contexts.count, 3)
        configuration.placementsByPanelID["components"] = []
        coordinator.synchronize(configuration: configuration, pluginOrder: ["example", "other"], visiblePanelID: nil)
        XCTAssertFalse(coordinator.isWidgetViewCached(id))
    }

}
