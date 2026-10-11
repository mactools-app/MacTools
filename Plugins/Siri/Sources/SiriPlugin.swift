import AppKit
import ApplicationServices
import MacToolsPluginKit
import SwiftUI

public final class SiriPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SiriPluginProvider(context: context)
    }
}

@MainActor private struct SiriPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] { [SiriPlugin(context: context)] }
}

@MainActor
final class SiriPlugin: MacToolsPlugin, PluginActionProviding, PluginActionInputProviding, PluginActionInputPresentationRequesting, PluginActionExposureProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ID {
        static let permission = "accessibility"
        static let ask = ActionKey(providerID: "siri", actionID: "ask-new-conversation")
    }
    var metadata: PluginMetadata {
        PluginMetadata(id: "siri", title: "Siri", iconName: "sparkles", iconTint: .purple,
                                  order: 101, defaultDescription: localization.string("metadata.description", defaultValue: "从命令面板向 Siri 发送消息"))
    }
    var rowDescriptor: PluginPanelRowDescriptor {
        let title = controller.isBusy ? text("取消") : text("询问 Siri")
        return PluginPanelRowDescriptor(controlStyle: .button, menuActionBehavior: .keepPresented,
                                             buttonTitleProvider: { title })
    }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestActionInput: ((ActionKey) -> Void)?
    private let localization: PluginLocalization
    let controller: SiriController
    private var observers: [NSObjectProtocol] = []
    private var trusted = false
    private var available = false
    private var sessions: Set<UUID> = []

    init(context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "siri"), client: (any SiriClient)? = nil) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        controller = SiriController(client: client ?? SiriAccessibilityClient())
        controller.onChange = { [weak self] in self?.onStateChange?() }
        refresh()
    }
    private func text(_ value: String) -> String { localization.string(value, defaultValue: value) }

    func activate(context: PluginRuntimeContext) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }
    func deactivate(reason: PluginDeactivationReason) {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        sessions = []
        controller.cancel()
    }
    func refresh() {
        let nextTrusted = AXIsProcessTrusted()
        let nextAvailable = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.campo") != nil
        let changed = trusted != nextTrusted || available != nextAvailable
        trusted = nextTrusted
        available = nextAvailable
        if changed { onStateChange?() }
    }
    var permissionRequirements: [PluginPermissionRequirement] {
        [.init(id: ID.permission, kind: .accessibility, title: text("辅助功能"), description: text("允许向 Siri 输入并发送消息"))]
    }
    func permissionState(for permissionID: String) -> PluginPermissionState {
        .init(isGranted: trusted, footnote: nil)
    }
    func handlePermissionAction(id: String) { requestPermissionGuidance?(id) }
    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] { [ID.permission] }
    func exposurePolicy(for reference: ActionReference, on surface: ActionExposureSurface) -> ActionExposurePolicy { .excluded }

    var actionDefinitions: [ActionDefinition] {
        [.init(key: ID.ask, title: text("询问 Siri — 新对话"), description: metadata.defaultDescription,
               keywords: ["Siri", "ask siri"], systemImage: "sparkles",
               parameters: [.init(id: "message", title: text("消息"), kind: .string, privacy: .sensitive, portability: .localOnly)],
               externalInvocationPolicy: .unavailable, capabilities: [.foregroundInteractive, .cancellable, .reportsProgress],
               executionTimeoutSeconds: 50)]
    }
    var actionInputDescriptors: [ActionInputDescriptor] {
        [.init(key: ID.ask, parameterID: "message", placeholder: text("输入发给 Siri 的消息"),
               destination: text("Siri · 新对话"), submitTitle: text("发送"), aliases: ["ask siri"])]
    }
    func prepareActionInput(_ descriptor: ActionInputDescriptor) async throws -> ActionInputSession {
        refresh()
        guard descriptor == actionInputDescriptors.first, available, trusted, !controller.isBusy else {
            throw SiriFailure.unavailable
        }
        let session = ActionInputSession(destination: descriptor.destination)
        sessions.insert(session.id)
        return session
    }
    func releaseActionInput(_ session: ActionInputSession) { sessions.remove(session.id) }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard available else { return .unavailable(text("需要 macOS 27 和 Siri AI")) }
        guard trusted else { return .unavailable(text("请先授予辅助功能权限")) }
        guard !controller.isBusy else { return .unavailable(text("正在向 Siri 发送消息")) }
        return .available
    }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        refresh()
        guard invocation.source == .unifiedSearch, invocation.mode == .foreground,
              invocation.reference.key == ID.ask, trusted, available,
              case let .string(message)? = invocation.reference.parameters["message"],
              let handle = controller.start(message) else { return ActionExecutionHandle { .failed(message: self.text("Siri 暂不可用")) } }
        return handle
    }
    var rowState: PluginPanelRowState {
        .init(subtitle: status, isOn: controller.isBusy, isEnabled: true,
              isAvailable: true, detail: nil, errorMessage: controller.failure == nil ? nil : status)
    }
    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == "execute" else { return }
        if controller.isBusy { controller.cancel() }
        else { requestActionInput?(ID.ask) }
    }
    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(id: "status", title: text("Siri"), systemImage: "sparkles") { [self] _ in
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(status).font(PluginSettingsTheme.Typography.rowTitle)
                    Text(text("在命令面板输入触发短语和消息，按 Return 发送。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    if controller.isBusy {
                        Button(text("取消")) { self.controller.cancel() }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            },
        ])
    }
    private var status: String {
        if let failure = controller.failure {
            let value = switch failure {
            case .existingDraft: "Siri 中有未发送的草稿，请先处理。"
            case .permission: "请先授予辅助功能权限"
            case .ambiguousWindow: "请选择要使用的 Siri 窗口后重试。"
            case .destinationChanged: "Siri 对话已更改，已停止发送。"
            case .textMismatch: "消息内容已更改，已停止发送。"
            case .submissionUncertain: "消息可能已发送，请在 Siri 中确认，避免重复发送。"
            case .timedOut: "等待 Siri 超时，请检查 Siri 后重试。"
            case .missingControls: "无法识别 Siri 输入界面，请检查 Siri 后重试。"
            case .unavailable: "Siri 暂不可用"
            }
            return text(value)
        }
        let value = switch controller.phase {
        case .idle: available ? "开始新的 Siri 对话" : "需要 macOS 27 和 Siri AI"
        case .opening: "正在打开 Siri…"
        case .preparing: "正在准备新对话…"
        case .entering: "正在输入消息…"
        case .submitting, .verifying: "正在发送消息…"
        case .sent: "消息已发送"
        case .cancelled: "已取消；Siri 中的草稿会保留。"
        case .failed: "Siri 暂不可用"
        case .uncertain: "消息可能已发送，请在 Siri 中确认，避免重复发送。"
        }
        return text(value)
    }
}
