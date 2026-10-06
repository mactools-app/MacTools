import CoreAudio
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class SystemMutePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemMutePluginProvider(context: context)
    }
}

@MainActor
private struct SystemMutePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SystemMutePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

protocol SystemAudioControlling {
    func readMuteState() -> Bool
    func setMuteState(_ muted: Bool) -> Bool
}

struct CoreAudioSystemOutputController: SystemAudioControlling {
    func readMuteState() -> Bool {
        guard let deviceID = Self.defaultOutputDeviceID() else { return false }
        return Self.getMuteState(deviceID: deviceID) ?? false
    }

    func setMuteState(_ muted: Bool) -> Bool {
        guard let deviceID = Self.defaultOutputDeviceID() else { return false }
        return Self.applyMuteState(deviceID: deviceID, muted: muted)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func getMuteState(deviceID: AudioDeviceID) -> Bool? {
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute)
        guard status == noErr else { return nil }
        return mute != 0
    }

    private static func applyMuteState(deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var mute: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute)
        return status == noErr
    }
}

@MainActor
final class SystemMutePlugin: MacToolsPlugin, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .toggle,
                state: state,
                menuActionBehavior: rowDescriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let toggle = "toggle"
    }

    private enum ErrorState {
        case muteFailed
        case unmuteFailed
    }
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "system-mute",
            title: localization.string("metadata.title", defaultValue: "系统静音"),
            iconName: "speaker.slash",
            iconTint: Color(nsColor: .systemOrange),
            order: 48,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速静音或恢复系统音频输出"
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

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SystemMutePlugin"
    )
    private let localization: PluginLocalization
    private let controller: any SystemAudioControlling
    private var isMuted: Bool = false
    private var lastErrorState: ErrorState?

    private var lastErrorMessage: String? {
        switch lastErrorState {
        case .muteFailed:
            localization.string("error.muteFailed", defaultValue: "静音操作失败")
        case .unmuteFailed:
            localization.string("error.unmuteFailed", defaultValue: "取消静音失败")
        case nil:
            nil
        }
    }

    init(
        controller: any SystemAudioControlling = CoreAudioSystemOutputController(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller
        self.isMuted = controller.readMuteState()
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: isMuted
                ? localization.string("panel.subtitle.muted", defaultValue: "已静音")
                : localization.string("panel.subtitle.unmuted", defaultValue: "未静音"),
            isOn: isMuted,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "系统静音"),
                description: localization.string("metadata.description", defaultValue: "快速静音或恢复系统音频输出"),
                keywords: [
                    localization.string("metadata.title", defaultValue: "系统静音"),
                    localization.string("metadata.description", defaultValue: "快速静音或恢复系统音频输出"),
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("action.setMute.title", defaultValue: "设置系统静音"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "快速静音或恢复系统音频输出"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "系统静音"),
                    localization.string("metadata.description", defaultValue: "快速静音或恢复系统音频输出"),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("action.setMute.title", defaultValue: "设置系统静音"),
                        kind: .boolean
                    ),
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
                title: isMuted
                    ? localization.string("action.unmute.title", defaultValue: "恢复系统音频")
                    : localization.string("action.mute.title", defaultValue: "静音系统音频"),
                subtitle: isMuted
                    ? localization.string("panel.subtitle.muted", defaultValue: "已静音")
                    : localization.string("panel.subtitle.unmuted", defaultValue: "未静音"),
                presentationState: isMuted ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.mute.title", defaultValue: "静音系统音频")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.unmute.title", defaultValue: "恢复系统音频")
            ),
        ]
    }

    func refresh() {
        let current = controller.readMuteState()
        if current != isMuted {
            isMuted = current
            onStateChange?()
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup, isMuted else { return }
        _ = controller.setMuteState(false)
        isMuted = false
        onStateChange?()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        applyMute(enable)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !controller.readMuteState()
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = applyMute(enabled)
        let message = lastErrorMessage
        let failureMessage = message
            ?? localization.string("error.muteFailed", defaultValue: "静音操作失败")
        return ActionExecutionHandle {
            succeeded
                ? .succeeded()
                : .failed(message: failureMessage)
        }
    }

    // MARK: - Private

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
    private func applyMute(_ muted: Bool) -> Bool {
        let success = controller.setMuteState(muted)
        if success {
            isMuted = muted
            lastErrorState = nil
        } else {
            logger.error("Failed to set system mute to \(muted, privacy: .public)")
            lastErrorState = muted ? .muteFailed : .unmuteFailed
        }
        onStateChange?()
        return success
    }
}
