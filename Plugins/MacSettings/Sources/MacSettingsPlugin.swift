import AppKit
import Foundation
import IOKit.hid
import SwiftUI
import MacToolsPluginKit

@MainActor
private final class MacSettingsInputDeviceObserver {
    private var manager: IOHIDManager?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceChanged, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func notifyChange() {
        onChange()
    }

    private nonisolated(unsafe) static let deviceChanged: IOHIDDeviceCallback = {
        context,
        _,
        _,
        _ in
        guard let context else { return }
        let observer = Unmanaged<MacSettingsInputDeviceObserver>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            observer.notifyChange()
        }
    }
}

@MainActor
final class MacSettingsActionContextBox {
    var context: PluginActionExecutionHostContext?
}

public final class MacSettingsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        try MainActor.assumeIsolated {
            try MacSettingsPluginProvider(context: context)
        }
    }
}

@MainActor
private struct MacSettingsPluginProvider: PluginProvider {
    let plugin: MacSettingsPlugin

    init(context: PluginRuntimeContext) throws {
        let actionContextBox = MacSettingsActionContextBox()
        let catalog = try MacSettingsCatalogFactory.make {
            actionContextBox.context
        }
        let controller = MacSettingsController(
            catalog: catalog,
            storage: context.storage
        )
        plugin = MacSettingsPlugin(
            controller: controller,
            actionContextBox: actionContextBox,
            localization: PluginLocalization(bundle: context.resourceBundle)
        )
    }

    func makePlugins() -> [any MacToolsPlugin] {
        [plugin]
    }
}

@MainActor
final class MacSettingsPlugin:
    MacToolsPlugin, PluginSettingsPresenting, PluginSettingsSearchFocusing, PluginActionProviding, PluginActionExecutionHostContextConsuming, PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting, PluginPortablePreferencesActionReferencesProviding, PluginActionReferenceBackupProviding, PluginPersistentPreferencesChangeSignaling {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ActionID {
        static let open = "open"
        static let openFavorites = "open-favorites"
        static let openCategory = "open-category"
        static let openSetting = "open-setting"
        static let search = "search"
        static let setBoolean = "set-boolean"
        static let applyProfile = "apply-profile"
        static let undo = "undo-most-recent-change"
        static let category = "category"
        static let query = "query"
        static let settingID = "setting-id"
        static let enabled = "enabled"
        static let profileID = "profile-id"
    }

    private enum ControlID {
        static let settingPrefix = "favorite-setting."
        static let openAll = "open-all-settings"
    }

    private struct PortablePreferences: Codable {
        let version: Int
        let favorites: [SystemSettingID]
        let density: MacSettingsWorkspaceDensity
        let profiles: [SystemSettingsProfile]
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "mac-settings",
            title: localization.string("metadata.title", defaultValue: "Mac Settings"),
            iconName: "slider.horizontal.3",
            iconTint: .accentColor,
            order: 18,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "Search and adjust common settings for this Mac in one place."
            )
        )
    }
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)? {
        didSet { controller.onPersistentPreferencesChange = onPersistentPreferencesChange }
    }
    var actionExecutionHostContext: PluginActionExecutionHostContext? {
        didSet {
            actionContextBox.context = actionExecutionHostContext
            updateProviderAvailability()
        }
    }

    private let controller: MacSettingsController
    private let actionContextBox: MacSettingsActionContextBox
    private let localization: PluginLocalization
    private let openSystemSettings: (URL) -> Void
    private var isExpanded = false
    private var inputDeviceObserver: MacSettingsInputDeviceObserver?
    private nonisolated(unsafe) var externalObservers: [NSObjectProtocol] = []

    init(
        controller: MacSettingsController,
        actionContextBox: MacSettingsActionContextBox = MacSettingsActionContextBox(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        openSystemSettings: @escaping (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
    ) {
        self.controller = controller
        self.actionContextBox = actionContextBox
        self.localization = localization
        self.openSystemSettings = openSystemSettings
        controller.onStateChange = { [weak self] in self?.onStateChange?() }
        controller.onPersistentPreferencesChange = { [weak self] in
            self?.onPersistentPreferencesChange?()
        }
        controller.onPermissionAction = { [weak self] permissionID in
            self?.handlePermissionAction(id: permissionID)
        }
        controller.onOpenSystemSettings = openSystemSettings
        controller.onOpenProviderSettings = { [weak actionContextBox] providerID in
            actionContextBox?.context?.openProviderSettings(providerID: providerID)
        }
        inputDeviceObserver = MacSettingsInputDeviceObserver { [weak controller] in
            controller?.scheduleExternalRefresh()
        }
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: MacSettingsStrings.format("Pinned: %@ · Needs attention: %@", "\(controller.favoriteIDs.count)", "\(controller.attentionCount)"),
            isOn: controller.attentionCount > 0,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? featurePanelDetail : nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        let affectedSettings = settingsRequiringPermission(MacSettingsPermission.fullDiskAccess)
            .map(\.definition.title)
            .formatted(.list(type: .and).locale(PluginRuntimeLocalization.locale))
        guard !affectedSettings.isEmpty else { return [] }
        return [
            PluginPermissionRequirement(
                id: MacSettingsPermission.fullDiskAccess,
                // PluginKit v5 has no Full Disk Access case. The host recognizes the stable
                // permission ID and supplies the correct shared presentation and action copy.
                kind: .automation,
                title: localization.string(
                    "permission.fullDiskAccess.title",
                    defaultValue: "Full Disk Access"
                ),
                description: localization.format(
                    "permission.fullDiskAccess.descriptionFormat",
                    defaultValue: "Used to change settings protected by macOS. Currently required for: %@.",
                    affectedSettings
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .selfManaged) { _ in
            MacSettingsWorkspaceView(controller: self.controller)
        }
        .onVisibilityChange { [weak controller] visible in
            if visible { controller?.refresh() } else { controller?.cancelRefresh() }
        }
    }

    var actionDefinitions: [ActionDefinition] {
        [
            navigationAction(
                id: ActionID.open,
                title: MacSettingsStrings.text("Open Mac Settings"),
                description: metadata.defaultDescription,
                parameters: []
            ),
            navigationAction(
                id: ActionID.openFavorites,
                title: MacSettingsStrings.text("Open Pinned Mac Settings"),
                description: MacSettingsStrings.text("Open frequently used settings with direct controls."),
                parameters: []
            ),
            navigationAction(
                id: ActionID.openCategory,
                title: MacSettingsStrings.text("Open Mac Settings Category"),
                description: MacSettingsStrings.text("Open a specific Mac Settings category."),
                parameters: [
                    ActionParameterDefinition(
                        id: ActionID.category,
                        title: MacSettingsStrings.text("Category"),
                        kind: .string
                    ),
                ]
            ),
            navigationAction(
                id: ActionID.openSetting,
                title: MacSettingsStrings.text("Open Mac Setting"),
                description: MacSettingsStrings.text("Open a specific Mac setting with its direct controls."),
                parameters: [
                    ActionParameterDefinition(
                        id: ActionID.settingID,
                        title: MacSettingsStrings.text("Setting ID"),
                        kind: .string
                    ),
                ]
            ),
            navigationAction(
                id: ActionID.search,
                title: MacSettingsStrings.text("Search Mac Settings"),
                description: MacSettingsStrings.text("Open Mac Settings and search titles, descriptions, and aliases."),
                parameters: [
                    ActionParameterDefinition(
                        id: ActionID.query,
                        title: MacSettingsStrings.text("Search Query"),
                        kind: .string,
                        isRequired: false
                    ),
                ]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setBoolean),
                title: MacSettingsStrings.text("Set Mac Setting On or Off"),
                description: MacSettingsStrings.text("Explicitly turn a supported Mac setting on or off."),
                keywords: ["Mac 设置", "打开设置", "关闭设置"],
                systemImage: "switch.2",
                parameters: [
                    ActionParameterDefinition(id: ActionID.settingID, title: MacSettingsStrings.text("Setting ID"), kind: .string),
                    ActionParameterDefinition(id: ActionID.enabled, title: MacSettingsStrings.text("On"), kind: .boolean),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.applyProfile),
                title: MacSettingsStrings.text("Apply Mac Settings Profile"),
                description: MacSettingsStrings.text("Preview and apply a saved settings profile."),
                keywords: ["配置", "profile", "应用设置"],
                systemImage: "square.stack.3d.up",
                parameters: [
                    ActionParameterDefinition(id: ActionID.profileID, title: MacSettingsStrings.text("Profile ID"), kind: .string),
                ],
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: MacSettingsStrings.text("Apply Mac Settings profile?"),
                    message: MacSettingsStrings.text("MacTools will open a profile preview. Settings change only after you confirm your selection."),
                    confirmButtonTitle: MacSettingsStrings.text("Open Preview")
                ),
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive, .opensInterface]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.undo),
                title: MacSettingsStrings.text("Undo Last Mac Settings Change"),
                description: MacSettingsStrings.text("Restore the most recent setting that supports rollback."),
                keywords: ["撤销设置", "undo setting", "恢复"],
                systemImage: "arrow.uturn.backward",
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(reference: reference(ActionID.open), title: MacSettingsStrings.text("Open Mac Settings")),
            ActionCatalogEntry(reference: reference(ActionID.openFavorites), title: MacSettingsStrings.text("Open Pinned Mac Settings")),
            ActionCatalogEntry(reference: reference(ActionID.undo), title: MacSettingsStrings.text("Undo Last Mac Settings Change")),
        ] + controller.availableCategories.map { category in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.openCategory),
                    parameters: try! ActionParameterSet([
                        ActionID.category: .string(category.rawValue),
                    ])
                ),
                title: MacSettingsStrings.format("Open Category · %@", "\(category.title)")
            )
        } + controller.catalog.records.map { record in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.openSetting),
                    parameters: try! ActionParameterSet([
                        ActionID.settingID: .string(record.id.rawValue),
                    ])
                ),
                title: MacSettingsStrings.format("Open Setting · %@", "\(record.definition.title)")
            )
        } + controller.profiles.map { profile in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.applyProfile),
                    parameters: try! ActionParameterSet([
                        ActionID.profileID: .string(profile.id.uuidString.lowercased()),
                    ])
                ),
                title: MacSettingsStrings.format("Apply Profile · %@", "\(profile.name)")
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        switch reference.key.actionID {
        case ActionID.undo:
            return controller.mostRecentUndoableChange != nil
                ? .available
                : .unavailable(MacSettingsStrings.text("There are no changes to undo."))
        case ActionID.setBoolean:
            guard let settingID = stringParameter(ActionID.settingID, in: reference),
                  case .boolean? = reference.parameters[ActionID.enabled],
                  let record = controller.catalog[SystemSettingID(rawValue: settingID)],
                  case .boolean = record.definition.schema,
                  let state = controller.rowStates[record.id],
                  state.errorMessage == nil,
                  !state.isApplying, controller.canEditSettings,
                  isControllable(state.availability) else {
                return .unavailable(MacSettingsStrings.text("This setting is currently unavailable."))
            }
            return .available
        case ActionID.applyProfile:
            guard let profileID = stringParameter(ActionID.profileID, in: reference),
                  let uuid = UUID(uuidString: profileID),
                  controller.profiles.contains(where: { $0.id == uuid }) else {
                return .unavailable(MacSettingsStrings.text("The profile is unavailable."))
            }
            return .available
        case ActionID.openSetting:
            guard let settingID = stringParameter(ActionID.settingID, in: reference),
                  controller.catalog[SystemSettingID(rawValue: settingID)] != nil else {
                return .unavailable(MacSettingsStrings.text("The setting is unavailable."))
            }
            return .available
        default:
            return .available
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        switch invocation.reference.key.actionID {
        case ActionID.open:
            return navigationHandle(destination: .all)
        case ActionID.openFavorites:
            return navigationHandle(destination: .favorites)
        case ActionID.openCategory:
            guard let rawCategory = stringParameter(ActionID.category, in: invocation.reference),
                  let category = SystemSettingCategory(rawValue: rawCategory) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.showCategoryResults(category)
                requestSettingsPresentation?()
                return .succeeded()
            }
        case ActionID.openSetting:
            guard let rawID = stringParameter(ActionID.settingID, in: invocation.reference),
                  let record = controller.catalog[SystemSettingID(rawValue: rawID)] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.showSetting(record.id)
                requestSettingsPresentation?()
                return .succeeded()
            }
        case ActionID.search:
            let query = stringParameter(ActionID.query, in: invocation.reference) ?? ""
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.destination = .all
                controller.searchText = query
                controller.requestSearchFocus()
                requestSettingsPresentation?()
                return .succeeded()
            }
        case ActionID.setBoolean:
            guard let rawID = stringParameter(ActionID.settingID, in: invocation.reference),
                  case let .boolean(enabled)? = invocation.reference.parameters[ActionID.enabled],
                  let record = controller.catalog[SystemSettingID(rawValue: rawID)],
                  case .boolean = record.definition.schema else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak controller] in
                guard let controller else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                return await controller.applyAndWait(.boolean(enabled), to: record)
                    ? .succeeded()
                    : .failed(message: controller.rowStates[record.id]?.errorMessage ?? PluginKitLocalization.actionFailed)
            }
        case ActionID.applyProfile:
            guard let rawID = stringParameter(ActionID.profileID, in: invocation.reference),
                  let id = UUID(uuidString: rawID),
                  let profile = controller.profiles.first(where: { $0.id == id }) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                controller.preparePlan(for: profile)
                controller.destination = .profiles
                requestSettingsPresentation?()
                return .succeeded(message: MacSettingsStrings.text("Preview and select the changes to apply."))
            }
        case ActionID.undo:
            return ActionExecutionHandle { [weak controller] in
                guard let controller else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                return await controller.undoMostRecentChange()
                    ? .succeeded()
                    : .failed(message: MacSettingsStrings.text("There are no changes to undo."))
            }
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
    }

    func refresh() {
        controller.refresh()
    }

    func activate(context: PluginRuntimeContext) {
        controller.activate()
        guard externalObservers.isEmpty else { return }
        inputDeviceObserver?.start()
        let center = NotificationCenter.default
        externalObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in controller?.scheduleExternalRefresh() }
        })
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.deactivate()
        inputDeviceObserver?.stop()
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        for observer in externalObservers {
            center.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        externalObservers = []
    }

    func focusSettingsSearch() {
        controller.requestSearchFocus()
    }

    func actionExecutionCatalogDidChange() {
        updateProviderAvailability()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if expanded { controller.refresh() }
            onStateChange?()
        case let .invokeAction(controlID):
            if controlID == ControlID.openAll {
                controller.destination = .all
                requestSettingsPresentation?()
            } else if let record = favoriteRecord(controlID),
                      case let .boolean(value)? = controller.rowStates[record.id]?.value {
                controller.apply(.boolean(!value), to: record.id)
            }
        case let .setSelection(controlID, optionID):
            if let record = favoriteRecord(controlID) {
                controller.apply(.choice(id: optionID), to: record.id)
            }
        case let .setSlider(controlID, value, phase):
            guard phase == .ended, let record = favoriteRecord(controlID) else { return }
            switch record.definition.schema {
            case .integer:
                controller.apply(.integer(Int(value.rounded())), to: record.id)
            case .decimal:
                controller.apply(.decimal(value), to: record.id)
            default:
                break
            }
        case .setSwitch, .setNavigationSelection, .clearNavigationSelection, .setDate:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == MacSettingsPermission.fullDiskAccess else {
            return .init(isGranted: true, footnote: nil)
        }
        let isGranted = controller.isPermissionGranted(permissionID)
        return .init(
            isGranted: isGranted,
            footnote: isGranted ? nil : localization.string(
                "permission.fullDiskAccess.footnote",
                defaultValue: "After granting access in System Settings, quit and reopen MacTools."
            )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == MacSettingsPermission.fullDiskAccess,
              let url = MacSettingsPermission.fullDiskAccessSettingsURL else { return }
        openSystemSettings(url)
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    private func settingsRequiringPermission(
        _ permissionID: String
    ) -> [SystemSettingRecord] {
        controller.catalog.records.filter {
            $0.definition.requirements.requiredPermissionID == permissionID
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        let payload = PortablePreferences(
            version: 1,
            favorites: controller.favoriteIDs,
            density: controller.density,
            profiles: controller.profiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              data.count <= SystemSettingsProfileCodec.maximumFileSize else { return nil }
        return data
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesReportingResult(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard data.count <= SystemSettingsProfileCodec.maximumFileSize else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PortablePreferences.self, from: data),
              payload.version == 1,
              payload.profiles.allSatisfy({
                  SystemSettingsProfileCodec.validate($0, catalog: controller.catalog).isValid
              }) else { return false }
        return controller.restorePortablePreferences(
            favorites: payload.favorites, density: payload.density, profiles: payload.profiles
        )
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        guard data.count <= SystemSettingsProfileCodec.maximumFileSize else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PortablePreferences.self, from: data),
              payload.version == 1 else { return nil }
        return payload.profiles.map { profile in
            ActionReference(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.applyProfile),
                parameters: try! ActionParameterSet([
                    ActionID.profileID: .string(profile.id.uuidString.lowercased()),
                ])
            )
        }
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        guard reference.key.providerID == metadata.id else { return .excluded }
        switch reference.key.actionID {
        case ActionID.applyProfile:
            return .requiresPluginPreferences
        case ActionID.undo:
            return .excluded
        case ActionID.open, ActionID.openFavorites, ActionID.openCategory, ActionID.openSetting,
             ActionID.search, ActionID.setBoolean:
            return .selfContained
        default:
            return .excluded
        }
    }

    private var featurePanelDetail: PluginPanelDetail {
        let favoriteControls = controller.favoriteRecordsForFeaturePanel.compactMap(featureControl)
        let openControl = PluginPanelControl(
            id: ControlID.openAll,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: MacSettingsStrings.text("Open All Settings…"),
            actionIconSystemName: "arrow.up.forward.app",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: !favoriteControls.isEmpty,
            isEnabled: true
        )
        return PluginPanelDetail(controls: favoriteControls + [openControl])
    }

    private func featureControl(_ record: SystemSettingRecord) -> PluginPanelControl? {
        guard let state = controller.rowStates[record.id], let value = state.value else { return nil }
        let id = ControlID.settingPrefix + record.id.rawValue
        let enabled = isControllable(state.availability)
            && state.errorMessage == nil
            && !state.isApplying
            && controller.canEditSettings
        switch (record.definition.schema, value) {
        case let (.boolean, .boolean(isOn)):
            return PluginPanelControl(
                id: id,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: "\(record.definition.title) · \(isOn ? MacSettingsStrings.text("On") : MacSettingsStrings.text("Off"))",
                actionIconSystemName: isOn ? "checkmark.circle.fill" : "circle",
                isEnabled: enabled
            )
        case let (.choice(options), .choice(selectionID)):
            return PluginPanelControl(
                id: id,
                kind: options.count > 3 ? .selectList : .segmented,
                options: options.map { .init(id: $0.id, title: $0.title) },
                selectedOptionID: selectionID,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: record.definition.title,
                isEnabled: enabled
            )
        case let (.integer(range, step), .integer(integer)):
            return sliderControl(
                id: id,
                title: record.definition.title,
                value: Double(integer),
                bounds: Double(range.lowerBound) ... Double(range.upperBound),
                step: Double(step),
                enabled: enabled
            )
        case let (.decimal(range, step), .decimal(value)):
            return sliderControl(
                id: id,
                title: record.definition.title,
                value: value,
                bounds: range,
                step: step ?? 0.01,
                enabled: enabled
            )
        default:
            return PluginPanelControl(
                id: ControlID.openAll,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: "\(record.definition.title) · \(value.conciseDescription)",
                actionIconSystemName: "arrow.up.forward.app",
                isEnabled: true
            )
        }
    }

    private func sliderControl(
        id: String,
        title: String,
        value: Double,
        bounds: ClosedRange<Double>,
        step: Double,
        enabled: Bool
    ) -> PluginPanelControl {
        PluginPanelControl(
            id: id,
            kind: .slider,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: title,
            sliderValue: value,
            sliderBounds: bounds,
            sliderStep: step,
            valueLabel: value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(PluginRuntimeLocalization.locale)),
            isEnabled: enabled
        )
    }

    private func favoriteRecord(_ controlID: String) -> SystemSettingRecord? {
        guard controlID.hasPrefix(ControlID.settingPrefix) else { return nil }
        return controller.catalog[
            SystemSettingID(rawValue: String(controlID.dropFirst(ControlID.settingPrefix.count)))
        ]
    }

    private func updateProviderAvailability() {
        let providerIDs = [
            "appearance",
            "auto-hide-dock",
            "auto-hide-menu-bar",
            "display-true-color",
            "night-shift",
            "stage-manager",
        ]
        let availability = Dictionary(uniqueKeysWithValues: providerIDs.map { providerID in
            let isAppearance = providerID == "appearance"
            let reference = ActionReference(
                key: ActionKey(providerID: providerID, actionID: isAppearance ? "set-mode" : "set-enabled"),
                parameters: try! ActionParameterSet(isAppearance ? ["mode": .string("auto")] : ["enabled": .boolean(true)])
            )
            return (providerID, actionExecutionHostContext?.item(for: reference)?.availability
                ?? .unavailable(MacSettingsStrings.text("The required MacTools plugin is not installed or enabled.")))
        })
        controller.updateProviderAvailability(availability)
    }

    private func navigationHandle(destination: MacSettingsDestination) -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
            if destination == .favorites { controller.showFavorites() }
            else { controller.destination = destination }
            requestSettingsPresentation?()
            return .succeeded()
        }
    }

    private func navigationAction(
        id: String,
        title: String,
        description: String,
        parameters: [ActionParameterDefinition]
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: id),
            title: title,
            description: description,
            keywords: ["Mac 设置", "系统设置", "settings"],
            systemImage: metadata.iconName,
            parameters: parameters,
            externalInvocationPolicy: .allowed,
            capabilities: [.foregroundInteractive, .opensInterface]
        )
    }

    private func reference(_ actionID: String) -> ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: actionID))
    }

    private func stringParameter(_ id: String, in reference: ActionReference) -> String? {
        guard case let .string(value)? = reference.parameters[id] else { return nil }
        return value
    }

    private func isControllable(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart: true
        default: false
        }
    }
}
