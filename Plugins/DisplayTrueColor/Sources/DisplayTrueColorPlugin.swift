import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class DisplayTrueColorPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplayTrueColorPluginProvider(context: context)
    }
}

@MainActor
private struct DisplayTrueColorPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DisplayTrueColorPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

/// Controls True Tone through CoreBrightness's private `CBAdaptationClient`.
@MainActor
final class DisplayTrueColorPlugin: MacToolsPlugin, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .toggle,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let toggle = "toggle"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "display-true-color",
            title: localization.string("metadata.title", defaultValue: "原彩显示"),
            iconName: "circle.righthalf.filled",
            iconTint: Color(nsColor: .systemCyan),
            order: 25,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自动调节显示器颜色以适应环境光"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayTrueColorPlugin")
    private let localization: PluginLocalization
    private let client: TrueToneClient
    private var isTrueColorEnabled: Bool = false
    private var isSupported: Bool = false

    init(
        client: TrueToneClient = CoreBrightnessTrueToneClient(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.client = client
        isSupported = client.isSupported
        isTrueColorEnabled = isSupported ? (client.isEnabled ?? false) : false
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: subtitle,
            isOn: isTrueColorEnabled,
            isEnabled: isSupported,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "True Tone"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "True Tone"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(id: "enabled", title: metadata.title, kind: .boolean),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: isTrueColorEnabled
                    ? localization.string("action.disable.title", defaultValue: "关闭原彩显示")
                    : localization.string("action.enable.title", defaultValue: "开启原彩显示"),
                subtitle: subtitle,
                presentationState: isTrueColorEnabled ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.enabled", defaultValue: "已开启"))"
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.disabled", defaultValue: "已关闭"))"
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        isSupported
            ? .available
            : .unavailable(localization.string("panel.subtitle.unsupported", defaultValue: "不支持"))
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func refresh() {
        guard isSupported else { return }
        let current = client.isEnabled ?? false
        if current != isTrueColorEnabled {
            isTrueColorEnabled = current
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        _ = setEnabled(enable)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !(client.isEnabled ?? isTrueColorEnabled)
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setEnabled(enabled)
        let failureMessage = localization.string("panel.subtitle.unsupported", defaultValue: "不支持")
        return ActionExecutionHandle {
            succeeded ? .succeeded() : .failed(message: failureMessage)
        }
    }

    // MARK: - Private

    private var subtitle: String {
        if !isSupported {
            return localization.string("panel.subtitle.unsupported", defaultValue: "不支持")
        }
        return isTrueColorEnabled
            ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
            : localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    @discardableResult
    private func setEnabled(_ enabled: Bool) -> Bool {
        guard isSupported else { return false }
        guard client.setEnabled(enabled), client.isEnabled == enabled else {
            isTrueColorEnabled = client.isEnabled ?? isTrueColorEnabled
            onStateChange?()
            logger.error("True Tone did not reach requested state")
            return false
        }
        isTrueColorEnabled = enabled
        onStateChange?()
        logger.info("True Tone set to \(enabled ? "enabled" : "disabled")")
        return true
    }
}

// MARK: - TrueToneClient Protocol

@MainActor
protocol TrueToneClient {
    var isSupported: Bool { get }
    var isEnabled: Bool? { get }
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool
}

// MARK: - CoreBrightness Implementation

final class CoreBrightnessTrueToneClient: TrueToneClient {
    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool
    private typealias SetBoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void

    private let adaptationClient: NSObject?
    private let supportedSel = NSSelectorFromString("supported")
    private let getEnabledSel = NSSelectorFromString("getEnabled")
    private let setEnabledSel = NSSelectorFromString("setEnabled:")

    init() {
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")
        _ = bundle?.load()
        guard let cls = NSClassFromString("CBAdaptationClient") as? NSObject.Type else {
            adaptationClient = nil
            return
        }
        adaptationClient = cls.init()
    }

    var isSupported: Bool {
        guard let obj = adaptationClient,
              obj.responds(to: supportedSel),
              let imp = class_getMethodImplementation(type(of: obj), supportedSel) else {
            return false
        }
        return unsafeBitCast(imp, to: BoolIMP.self)(obj, supportedSel)
    }

    var isEnabled: Bool? {
        guard let obj = adaptationClient,
              obj.responds(to: getEnabledSel),
              let imp = class_getMethodImplementation(type(of: obj), getEnabledSel) else {
            return nil
        }
        return unsafeBitCast(imp, to: BoolIMP.self)(obj, getEnabledSel)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let obj = adaptationClient,
              obj.responds(to: setEnabledSel),
              let imp = class_getMethodImplementation(type(of: obj), setEnabledSel) else {
            return false
        }
        unsafeBitCast(imp, to: SetBoolIMP.self)(obj, setEnabledSel, enabled)
        return isEnabled == enabled
    }
}
