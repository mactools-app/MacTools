import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class AIAssistantPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AIAssistantPluginProvider(context: context)
    }
}

@MainActor
private struct AIAssistantPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AIAssistantPlugin(context: context)]
    }
}

@MainActor
final class AIAssistantPlugin:
    MacToolsPlugin,
    PluginSettingsPresenting,
    PluginActionProviding,
    PluginActionPermissionProviding,
    PluginShortcutEventHandling,
    PluginGroupedShortcutSettingsProviding,
    PluginShortcutBindingValidating,
    PluginFocusedWindowTargetConsuming
{
    private enum APIKeyState: Equatable {
        case unknown
        case present
        case missing
        case error(String)
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: AIAssistantConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "AI 助手"),
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: 58,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "划词调用 AI 翻译、总结、润色等"
            )
        )
    }

    private let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var focusedWindowTargetProvider: (() -> PluginFocusedWindowTarget?)?

    private let storage: PluginStorage
    private let accessibilityTrustProvider: () -> Bool
    private let accessibilityTrustRequester: (Bool) -> Bool
    private let secretStore: any AIAssistantSecretStoring
    private let panelController: any AIAssistantPanelControlling
    private let selectedTextCapturePipeline: SelectedTextCapturePipeline
    private let providerFactoryOverride: AIAssistantProviderFactory?
    private let clipboardTextProvider: () -> String?
    private let providerProfileStore: AIAssistantProviderProfileStore
    private let promptStore: AIAssistantPromptStore
    private let localization: PluginLocalization
    private var providerProfiles: [AIAssistantProviderProfile]
    private var prompts: [AIAssistantPrompt]
    private var cachedAPIKey: String?
    private var didLoadAPIKey = false
    private var apiKeyState: APIKeyState
    private var coordinator: AIAssistantCoordinator?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: AIAssistantConstants.pluginID),
        accessibilityTrustProvider: @escaping () -> Bool = AccessibilityCheck.isTrusted,
        accessibilityTrustRequester: @escaping (Bool) -> Bool = AccessibilityCheck.requestTrust,
        secretStore: any AIAssistantSecretStoring = AIAssistantSecretStore(),
        panelController: (any AIAssistantPanelControlling)? = nil,
        selectedTextCapturePipeline: SelectedTextCapturePipeline? = nil,
        providerFactoryOverride: AIAssistantProviderFactory? = nil,
        clipboardTextProvider: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.storage = context.storage
        self.accessibilityTrustProvider = accessibilityTrustProvider
        self.accessibilityTrustRequester = accessibilityTrustRequester
        self.secretStore = secretStore
        self.panelController = panelController ?? AIAssistantPanelController(localization: localization)
        self.selectedTextCapturePipeline = selectedTextCapturePipeline ?? .live(
            localization: localization,
            allowsSimulatedCopy: { context.storage.bool(forKey: AIAssistantConstants.StorageKey.allowsSimulatedCopy) }
        )
        self.providerFactoryOverride = providerFactoryOverride
        self.clipboardTextProvider = clipboardTextProvider
        let providerProfileStore = AIAssistantProviderProfileStore(storage: context.storage, localization: localization)
        self.providerProfileStore = providerProfileStore
        self.providerProfiles = providerProfileStore.loadProfiles()
        self.promptStore = AIAssistantPromptStore(storage: context.storage, localization: localization)
        self.prompts = promptStore.loadPrompts()
        self.cachedAPIKey = nil
        self.apiKeyState = .unknown
        self.panelController.onAction = { [weak self] action in
            self?.handlePanelAction(action)
        }
    }

    var panelItems: [PluginPanelItem] {
        [
            .row(
                id: "control",
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] in self?.handleAction($0) }
            )
        ]
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: isShortcutEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: AIAssistantConstants.PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能授权"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "划词处理需要读取当前选中文本。"
                )
            ),
            PluginPermissionRequirement(
                id: AIAssistantConstants.PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "自动化授权"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "浏览器划词可能需要允许 MacTools 控制当前浏览器。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        // Retain editable definitions while making inactive shortcuts ineligible
        // for global registration.
        prompts
            .map { prompt in
                PluginShortcutDefinition(
                    id: Self.shortcutID(for: prompt.id),
                    title: prompt.normalizedName,
                    description: shortcutDescription(for: prompt),
                    actionID: prompt.id,
                    scope: isShortcutEnabled && prompt.isEnabled ? .global : .whilePluginActive,
                    defaultBinding: defaultBinding(for: prompt),
                    isRequired: false
                )
            }
    }

    /// Returns the default shortcut binding for built-in prompts
    /// (Option+1 / Option+2 / Option+3); custom prompts have no default.
    private func defaultBinding(for prompt: AIAssistantPrompt) -> ShortcutBinding? {
        switch prompt.id {
        case "translate":
            return AIAssistantConstants.Defaults.translateShortcut
        case "summarize":
            return AIAssistantConstants.Defaults.summarizeShortcut
        case "polish":
            return AIAssistantConstants.Defaults.polishShortcut
        default:
            return nil
        }
    }

    private func shortcutDescription(for prompt: AIAssistantPrompt) -> String {
        if shortcutUsesClipboard {
            return localization.format(
                "shortcut.prompt.clipboardDescriptionFormat",
                defaultValue: "用「%@」处理选中文本，未选中时使用剪贴板。",
                prompt.normalizedName
            )
        }
        return localization.format(
            "shortcut.prompt.descriptionFormat",
            defaultValue: "用「%@」处理当前选中文本。",
            prompt.normalizedName
        )
    }

    var actionDefinitions: [ActionDefinition] {
        prompts
            .filter(\.isEnabled)
            .map { prompt in
                ActionDefinition(
                    key: ActionKey(
                        providerID: metadata.id,
                        actionID: prompt.id
                    ),
                    title: prompt.normalizedName,
                    description: shortcutDescription(for: prompt),
                    keywords: [
                        localization.string("metadata.title", defaultValue: "AI 助手"),
                        prompt.normalizedName,
                    ],
                    systemImage: "sparkles",
                    externalInvocationPolicy: .allowed,
                    capabilities: [.foregroundInteractive]
                )
            }
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id else { return [] }
        if shortcutUsesClipboard { return [] }
        return [
            AIAssistantConstants.PermissionID.accessibility,
            AIAssistantConstants.PermissionID.automation,
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard isShortcutEnabled else {
            return .unavailable(
                localization.string(
                    "action.unavailable.paused",
                    defaultValue: "AI 助手快捷键已暂停。"
                )
            )
        }
        guard prompts.contains(where: { $0.id == reference.key.actionID && $0.isEnabled }) else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard shortcutUsesClipboard || accessibilityTrustProvider() else {
            return .unavailable(
                localization.string(
                    "action.unavailable.accessibility",
                    defaultValue: "需要辅助功能授权。"
                )
            )
        }
        guard !enabledValidProfiles.isEmpty else {
            return .unavailable(
                localization.string(
                    "action.unavailable.provider",
                    defaultValue: "请先配置 AI 服务。"
                )
            )
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        handleShortcutAction(id: invocation.reference.key.actionID)
        return ActionExecutionHandle { .succeeded() }
    }

    var shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] {
        [
            PluginShortcutSettingsGroupConfiguration(
                id: "ai-assistant-prompts",
                title: localization.string("settings.shortcuts.title", defaultValue: "快捷键"),
                systemImage: "command",
                shortcutDefinitionIDs: Set(prompts.map { Self.shortcutID(for: $0.id) })
            )
        ]
    }

    func shortcutValidationMessage(definitionID: String, binding: ShortcutBinding) -> String? {
        if CommonApplicationShortcutBindings.requiresConflictWarning(for: binding) {
            return localization.string(
                "settings.shortcut.conflict.system",
                defaultValue: "该快捷键与常用系统操作冲突，请使用包含 ⌥(Option) 或 ⌃(Control) 的组合键。"
            )
        }

        for prompt in prompts {
            let itemID = Self.shortcutID(for: prompt.id)
            if itemID != definitionID {
                if let otherBinding = shortcutBindingResolver?(itemID), otherBinding == binding {
                    return localization.format(
                        "settings.shortcut.conflict.duplicatePrompt",
                        defaultValue: "该快捷键已被模板「%@」占用，请更换其他按键组合。",
                        prompt.normalizedName
                    )
                }
            }
        }

        return nil
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "ai-service",
                title: localization.string("settings.service.title", defaultValue: "AI 服务"),
                systemImage: "sparkles",
                presentation: .edgeToEdge
            ) { [weak self] _ in
                if let self {
                    let localization = self.localization
                    AIAssistantServiceSettingsView(
                        profiles: self.providerProfiles,
                        apiKey: self.cachedAPIKey ?? "",
                        localization: localization,
                        onSave: { [weak self] profiles, apiKey in
                            self?.saveProviderConfiguration(profiles: profiles, apiKey: apiKey)
                        },
                        onFetchModels: { [weak self] profile, apiKey in
                            guard let self else {
                                return .failure(
                                    localization.string(
                                        "settings.modelList.unavailable",
                                        defaultValue: "暂时无法获取模型列表"
                                    )
                                )
                            }
                            return await self.fetchModels(profile: profile, apiKey: apiKey)
                        },
                        onTestConnection: { [weak self] profile, apiKey in
                            guard let self else {
                                return .failure(
                                    localization.string(
                                        "settings.test.unavailable",
                                        defaultValue: "暂时无法测试连接"
                                    )
                                )
                            }
                            return await self.testConnection(profile: profile, apiKey: apiKey)
                        }
                    )
                }
            },
            PluginSettingsSection(
                id: "shortcut-input",
                title: localization.string("settings.shortcutInput.title", defaultValue: "快捷键输入"),
                systemImage: "doc.on.clipboard",
                rows: [
                    PluginSettingsRow(
                        id: AIAssistantConstants.StorageKey.shortcutUsesClipboard,
                        title: localization.string("settings.shortcutInput.clipboard.title", defaultValue: "使用剪贴板"),
                        description: localization.string(
                            "settings.shortcutInput.clipboard.description",
                            defaultValue: "优先处理选中文本；未选中且剪贴板未变化时，使用已复制的文本。"
                        ),
                        systemImage: "doc.on.clipboard",
                        control: .toggle(isOn: shortcutUsesClipboard)
                    ),
                ]
            ),
            PluginSettingsSection(
                id: "selection-capture",
                title: localization.string("settings.capture.title", defaultValue: "划词捕获"),
                systemImage: "text.cursor",
                rows: [
                    PluginSettingsRow(
                        id: AIAssistantConstants.StorageKey.allowsSimulatedCopy,
                        title: localization.string("settings.capture.simulatedCopy.title", defaultValue: "允许模拟复制"),
                        description: localization.string(
                            "settings.capture.simulatedCopy.description",
                            defaultValue: "直接读取失败时模拟 ⌘C；复制内容可能进入剪贴板历史。"
                        ),
                        systemImage: "doc.on.doc",
                        control: .toggle(isOn: allowsSimulatedCopy)
                    ),
                ]
            ),
            PluginSettingsSection(
                id: "ai-prompts",
                title: localization.string("settings.prompts.title", defaultValue: "处理模板"),
                systemImage: "square.stack.3d.up",
                presentation: .edgeToEdge,
                embeddedShortcutGroupIDs: ["ai-assistant-prompts"]
            ) { [weak self] settingsContext in
                if let self {
                    let localization = self.localization
                    AIAssistantPromptSettingsView(
                        prompts: self.prompts,
                        localization: localization,
                        settingsContext: settingsContext,
                        shortcutItemProvider: { prompt in
                            settingsContext.shortcutItem(definitionID: Self.shortcutID(for: prompt.id))
                        },
                        onPromptsChanged: { [weak self] prompts in
                            self?.savePromptsConfiguration(prompts)
                        },
                        onMakeNewPrompt: { [weak self] existing in
                            self?.promptStore.makeNewPrompt(existing: existing)
                                ?? AIAssistantPrompt(
                                    id: UUID().uuidString,
                                    name: localization.format("prompt.newDefaultName", defaultValue: "新模板 %d", existing.count + 1),
                                    template: "{{text}}",
                                    systemPrompt: nil,
                                    isEnabled: true
                                )
                        }
                    )
                }
            }
        ])
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        storage.set(isEnabled, forKey: AIAssistantConstants.StorageKey.shortcutEnabled)
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case AIAssistantConstants.PermissionID.accessibility:
            let isGranted = accessibilityTrustProvider()
            return PluginPermissionState(
                isGranted: isGranted,
                footnote: isGranted
                    ? nil
                    : localization.string(
                        "permission.accessibility.footnote",
                        defaultValue: "前往系统设置 → 隐私与安全性 → 辅助功能，授权 MacTools。"
                    )
            )
        case AIAssistantConstants.PermissionID.automation:
            return PluginPermissionState(
                isGranted: true,
                footnote: localization.string(
                    "permission.automation.footnote",
                    defaultValue: "MacTools 首次控制浏览器时，macOS 会请求自动化授权。"
                ),
                statusText: localization.string("permission.automation.status", defaultValue: "按需确认"),
                statusSystemImage: "sparkles",
                statusTone: .neutral
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case AIAssistantConstants.PermissionID.accessibility:
            _ = accessibilityTrustRequester(true)
            onStateChange?()
        case AIAssistantConstants.PermissionID.automation:
            requestPermissionGuidance?(AIAssistantConstants.PermissionID.automation)
            onStateChange?()
        default:
            return
        }
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setBoolean(controlID, value) = action,
              controlID == AIAssistantConstants.StorageKey.shortcutUsesClipboard
                || controlID == AIAssistantConstants.StorageKey.allowsSimulatedCopy else { return }
        storage.set(value, forKey: controlID)
        onStateChange?()
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else {
            return
        }

        if let coordinator {
            coordinator.close()
        } else {
            panelController.close()
        }
        coordinator = nil
    }

    func handleShortcutAction(id: String) {
        handleShortcutEvent(id: id, phase: .pressed)
    }

    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {
        guard phase == .pressed else {
            return
        }

        guard isShortcutEnabled else {
            return
        }

        guard let prompt = prompts.first(where: { $0.id == id }), prompt.isEnabled else {
            return
        }

        let coordinator = coordinator ?? makeCoordinator()
        self.coordinator = coordinator
        // Clipboard-enabled shortcuts still prefer a direct selection. A hidden
        // session is reopened only in selection-only mode.
        if !shortcutUsesClipboard, coordinator.hasSession(forPromptID: prompt.id), !coordinator.isPanelVisible {
            coordinator.reopenSession()
        } else {
            let context = SelectedTextCaptureContext(
                frontmostApplication: focusedWindowTargetProvider?()?.application
            )
            coordinator.startProcessing(
                prompt: prompt,
                context: context,
                useClipboardWhenNoSelection: shortcutUsesClipboard
            )
        }
    }

    // MARK: - Helpers

    private static let shortcutIDPrefix = "ai-assistant.prompt."

    private static func shortcutID(for promptID: String) -> String {
        "\(shortcutIDPrefix)\(promptID)"
    }

    private var isShortcutEnabled: Bool {
        guard storage.object(forKey: AIAssistantConstants.StorageKey.shortcutEnabled) != nil else {
            return AIAssistantConstants.Defaults.shortcutEnabled
        }

        return storage.bool(forKey: AIAssistantConstants.StorageKey.shortcutEnabled)
    }

    private var shortcutUsesClipboard: Bool {
        storage.bool(forKey: AIAssistantConstants.StorageKey.shortcutUsesClipboard)
    }

    private var allowsSimulatedCopy: Bool {
        storage.bool(forKey: AIAssistantConstants.StorageKey.allowsSimulatedCopy)
    }

    private var panelSubtitle: String {
        if !isShortcutEnabled {
            return localization.string("panel.subtitle.shortcutPaused", defaultValue: "快捷键已暂停")
        }
        if !shortcutUsesClipboard && !accessibilityTrustProvider() {
            return localization.string("panel.subtitle.permissionRequired", defaultValue: "启用前需要辅助功能授权")
        }
        if enabledValidProfiles.isEmpty {
            return localization.string("panel.subtitle.needsProvider", defaultValue: "需要配置 AI 服务")
        }

        switch apiKeyState {
        case .missing, .error:
            return localization.string("panel.subtitle.needsProvider", defaultValue: "需要配置 AI 服务")
        case .unknown, .present:
            if shortcutUsesClipboard {
                return localization.string("panel.subtitle.clipboardReady", defaultValue: "按下模板快捷键处理剪贴板文本")
            }
            return localization.string("panel.subtitle.ready", defaultValue: "按下模板快捷键处理选中文本")
        }
    }

    private var enabledValidProfiles: [AIAssistantProviderProfile] {
        providerProfiles.filter { $0.isEnabled && $0.validationError == nil }
    }

    private func handlePanelAction(_ action: AIAssistantPanelAction) {
        if action == .openSettings {
            requestSettingsPresentation?()
            return
        }

        if action == .hide {
            // Non-destructive: keep the session and the running task alive.
            coordinator?.hide()
            return
        }

        if action == .close {
            coordinator?.close()
            coordinator = nil
            panelController.close()
            return
        }

        guard let coordinator else { return }
        coordinator.handle(action)
    }

    private func makeCoordinator() -> AIAssistantCoordinator {
        AIAssistantCoordinator(
            selectedTextCapturePipeline: selectedTextCapturePipeline,
            providerFactory: providerFactoryOverride ?? { [weak self] in
                guard let self else {
                    return .failure(AIAssistantProviderError(
                        message: PluginLocalization(bundle: .main).string(
                            "panelError.missingProvider",
                            defaultValue: "请先配置 AI 服务"
                        )
                    ))
                }
                return self.resolveProvider()
            },
            panelController: panelController,
            clipboardTextProvider: clipboardTextProvider,
            localization: localization
        )
    }

    private func resolveProvider() -> Result<ResolvedAIProvider, AIAssistantProviderError> {
        guard let profile = enabledValidProfiles.first else {
            return .failure(AIAssistantProviderError(
                message: localization.string("panelError.missingProvider", defaultValue: "请先配置 AI 服务")
            ))
        }

        do {
            let apiKey = try loadAPIKey()
            guard let trimmedKey = Self.normalizedAPIKey(apiKey) else {
                return .failure(AIAssistantProviderError(
                    message: localization.string("panelError.missingAPIKey", defaultValue: "请配置 API Key")
                ))
            }

            return .success(
                ResolvedAIProvider(
                    title: profile.normalizedName,
                    client: OpenAICompatibleClient(localization: localization),
                    configuration: profile.configuration,
                    apiKey: trimmedKey
                )
            )
        } catch {
            return .failure(AIAssistantProviderError(message: userFacingMessage(for: error)))
        }
    }

    /// Lists available model IDs from the provider using the currently edited
    /// provider profile. The API key is resolved from the edited field first and
    /// falls back to the Keychain entry when the field is left blank.
    func fetchModels(
        profile: AIAssistantProviderProfile,
        apiKey: String
    ) async -> AIAssistantOutcome<[String]> {
        let resolved = await resolveAPIKey(preferred: apiKey)
        switch resolved {
        case let .failure(message):
            return .failure(message)
        case let .success(key):
            let client = OpenAICompatibleClient(localization: localization)
            do {
                let models = try await client.listModels(
                    configuration: profile.configuration,
                    apiKey: key
                )
                return .success(models)
            } catch {
                return .failure(userFacingMessage(for: error))
            }
        }
    }

    /// Sends a tiny completion request to verify the currently edited provider
    /// configuration, API key, and model. Returns a success message on a valid
    /// response, or a localized error otherwise.
    func testConnection(
        profile: AIAssistantProviderProfile,
        apiKey: String
    ) async -> AIAssistantOutcome<String> {
        if let validationError = profile.validationError {
            return .failure(validationError.errorDescription(localization: localization))
        }

        let resolved = await resolveAPIKey(preferred: apiKey)
        switch resolved {
        case let .failure(message):
            return .failure(message)
        case let .success(key):
            let client = OpenAICompatibleClient(localization: localization)
            do {
                _ = try await client.complete(
                    prompt: localization.string(
                        "settings.test.prompt",
                        defaultValue: "请回复：连接成功"
                    ),
                    systemPrompt: nil,
                    configuration: profile.configuration,
                    apiKey: key
                )
                return .success(
                    localization.string("settings.test.success", defaultValue: "连接成功")
                )
            } catch {
                return .failure(userFacingMessage(for: error))
            }
        }
    }

    /// Resolves the effective API key for a request, preferring the edited field
    /// and falling back to the stored Keychain entry. Runs on `@MainActor`.
    private func resolveAPIKey(preferred: String) async -> AIAssistantOutcome<String> {
        if let normalizedKey = Self.normalizedAPIKey(preferred) {
            return .success(normalizedKey)
        }

        do {
            let key = try loadAPIKey()
            if let normalizedKey = Self.normalizedAPIKey(key) {
                return .success(normalizedKey)
            }
            return .failure(
                localization.string("panelError.missingAPIKey", defaultValue: "请配置 API Key")
            )
        } catch {
            return .failure(userFacingMessage(for: error))
        }
    }

    private func loadAPIKey() throws -> String? {
        if didLoadAPIKey {
            return cachedAPIKey
        }

        let key = try secretStore.loadAPIKey()
        cachedAPIKey = key
        didLoadAPIKey = true
        apiKeyState = Self.hasNonEmptyAPIKey(key) ? .present : .missing
        return key
    }

    @discardableResult
    func saveProviderConfiguration(
        profiles: [AIAssistantProviderProfile],
        apiKey: String
    ) -> String? {
        guard profiles.contains(where: \.isEnabled) else {
            return localization.string("settings.error.noEnabledProvider", defaultValue: "至少启用一个 AI 服务。")
        }

        for profile in profiles where profile.isEnabled {
            if let validationError = profile.validationError {
                let title = profile.normalizedName.isEmpty
                    ? localization.string("settings.provider.fallbackName", defaultValue: "AI 服务")
                    : profile.normalizedName
                return localization.format(
                    "settings.error.providerValidationFormat",
                    defaultValue: "%@：%@",
                    title,
                    validationError.errorDescription(localization: localization)
                )
            }
        }

        do {
            if let normalizedAPIKey = Self.normalizedAPIKey(apiKey) {
                try secretStore.saveAPIKey(normalizedAPIKey)
                cachedAPIKey = normalizedAPIKey
                didLoadAPIKey = true
            }

            try providerProfileStore.saveProfiles(profiles)
            providerProfiles = providerProfileStore.loadProfiles()
            apiKeyState = .present
            if let coordinator {
                coordinator.close()
            } else {
                panelController.close()
            }
            coordinator = nil
            onStateChange?()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func savePromptsConfiguration(_ prompts: [AIAssistantPrompt]) -> String? {
        for prompt in prompts where prompt.isEnabled {
            if !prompt.template.contains("{{text}}") {
                return localization.format(
                    "settings.error.promptValidationFormat",
                    defaultValue: "%@：提示词必须包含 {{text}}。",
                    prompt.normalizedName.isEmpty
                        ? localization.string("settings.prompt.fallbackName", defaultValue: "处理模板")
                        : prompt.normalizedName
                )
            }
        }

        do {
            try promptStore.savePrompts(prompts)
            self.prompts = promptStore.loadPrompts()
            if let coordinator {
                coordinator.close()
            } else {
                panelController.close()
            }
            coordinator = nil
            onStateChange?()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveConfiguration(
        profiles: [AIAssistantProviderProfile],
        prompts: [AIAssistantPrompt],
        apiKey: String
    ) -> String? {
        if let error = saveProviderConfiguration(profiles: profiles, apiKey: apiKey) {
            return error
        }
        return savePromptsConfiguration(prompts)
    }

    private func userFacingMessage(for error: Error) -> String {
        AIAssistantUserFacingMessage.message(for: error, localization: localization)
    }

    private static func hasNonEmptyAPIKey(_ apiKey: String?) -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func normalizedAPIKey(_ apiKey: String?) -> String? {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedKey.isEmpty ? nil : trimmedKey
    }
}
