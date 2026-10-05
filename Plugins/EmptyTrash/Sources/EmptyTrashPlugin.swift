import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class EmptyTrashPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        EmptyTrashPluginProvider(context: context)
    }
}

@MainActor
private struct EmptyTrashPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [EmptyTrashPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class EmptyTrashPlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("control") }
                    else { self?.panelItemDidBecomeHidden("control") }
                },
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            )
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("quick-control") }
                    else { self?.panelItemDidBecomeHidden("quick-control") }
                },
        ]
    }

    private enum PermissionID {
        static let automation = "automation"
    }
    private enum ActionID {
        static let empty = "empty"
    }
    private enum TrashOperationError: Error {
        case countUnavailable
        case emptyFailed
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "empty-trash",
            title: localization.string("metadata.title", defaultValue: "清空废纸篓"),
            iconName: "trash",
            iconTint: Color(nsColor: .systemGray),
            order: 93,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "清空废纸篓中的所有项目"
            )
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let countItems: @Sendable () async throws -> Int
    private let emptyItems: () async throws -> Void
    private let countRefreshDelay: Duration
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EmptyTrashPlugin")
    private var itemCount: Int = 0
    private var isEmptying = false
    private var lastError: Error?
    private var lastErrorMessage: String? {
        guard let lastError else { return nil }
        switch lastError {
        case TrashOperationError.countUnavailable:
            return localization.string("error.countFailed", defaultValue: "无法读取废纸篓，请检查“自动化”权限。")
        case TrashOperationError.emptyFailed:
            return localization.string("error.emptyFailed", defaultValue: "清空废纸篓失败，请检查“自动操作”权限")
        default:
            return lastError.localizedDescription
        }
    }
    private var visiblePanelItems: Set<String> = []
    private var countRefreshTask: Task<Void, Never>?

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        countItems: @escaping @Sendable () async throws -> Int = EmptyTrashPlugin.fetchTrashItemCount,
        emptyItems: (() async throws -> Void)? = nil,
        countRefreshDelay: Duration = .milliseconds(150)
    ) {
        self.localization = localization
        self.countItems = countItems
        self.emptyItems = emptyItems ?? {
            try await EmptyTrashPlugin.emptyTrashViaAppleScript()
        }
        self.countRefreshDelay = countRefreshDelay
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: { localization.string("panel.button.empty", defaultValue: "清空") }
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: subtitle,
            isOn: false,
            isEnabled: !isEmptying && itemCount > 0,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "Finder 自动化"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "用于读取并清空废纸篓。"
                )
            )
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.empty),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "trash", "delete"],
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: localization.string("panel.button.empty", defaultValue: "清空")
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive],
                executionTimeoutSeconds: 600
            ),
        ]
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id, actionKey.actionID == ActionID.empty else {
            return []
        }
        return [PermissionID.automation]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.empty else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return isEmptying ? .unavailable(subtitle) : .available
    }

    func refresh() {
        scheduleCountRefreshIfVisible()
    }

    func deactivate(reason _: PluginDeactivationReason) {
        countRefreshTask?.cancel()
        countRefreshTask = nil
        visiblePanelItems.removeAll()
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "control" || surface == "quick-control" else {
            return
        }
        let wasHidden = visiblePanelItems.isEmpty
        visiblePanelItems.insert(surface)
        if wasHidden { scheduleCountRefresh() }
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard visiblePanelItems.remove(surface) != nil, visiblePanelItems.isEmpty else {
            return
        }
        countRefreshTask?.cancel()
        countRefreshTask = nil
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            if controlID == "execute" {
                emptyTrash()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.automation else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: lastErrorMessage == nil,
            footnote: lastErrorMessage
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.automation,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.empty else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.performCanonicalEmpty()
        }
    }

    // MARK: - Private

    private func scheduleCountRefresh() {
        countRefreshTask?.cancel()
        let delay = countRefreshDelay
        countRefreshTask = Task { @MainActor [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }

            do {
                let count = try await self.countItems()
                guard !Task.isCancelled else { return }
                self.lastError = nil
                if self.itemCount != count {
                    self.itemCount = count
                    self.onStateChange?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.itemCount = 0
                self.lastError = error
                self.onStateChange?()
            }
            self.countRefreshTask = nil
        }
    }

    private func scheduleCountRefreshIfVisible() {
        guard !visiblePanelItems.isEmpty else {
            return
        }

        scheduleCountRefresh()
    }

    private var subtitle: String {
        if isEmptying {
            return localization.string("panel.subtitle.emptying", defaultValue: "清空中...")
        }
        if itemCount == 0 {
            return localization.string("panel.subtitle.empty", defaultValue: "废纸篓为空")
        }
        return localization.format("panel.subtitle.countFormat", defaultValue: "%d 个项目", itemCount)
    }

    @MainActor
    private func emptyTrash() {
        guard !isEmptying, itemCount > 0 else { return }
        isEmptying = true
        lastError = nil
        onStateChange?()

        Task {
            _ = await self.finishEmptying()
        }
    }

    // MARK: - AppleScript helpers

    private static func fetchTrashItemCount() async throws -> Int {
        let script = "tell application \"Finder\" to count items of trash"
        return try await Task.detached(priority: .userInitiated) {
            guard let output = runOsascriptStandalone(script), let count = Int(output) else {
                throw TrashOperationError.countUnavailable
            }
            return count
        }.value
    }

    private static func emptyTrashViaAppleScript() async throws {
        let script = "tell application \"Finder\" to empty trash"
        try await Task.detached(priority: .userInitiated) {
             if runOsascriptStandalone(script) == nil {
                throw TrashOperationError.emptyFailed
            }
        }.value
    }

    private func performCanonicalEmpty() async -> ActionExecutionResult {
        guard !isEmptying else {
            return .failed(message: subtitle)
        }

        let count: Int
        do {
            count = try await countItems()
            itemCount = count
            lastError = nil
        } catch {
            itemCount = 0
            lastError = error
            onStateChange?()
            return .failed(message: lastErrorMessage ?? error.localizedDescription)
        }
        guard count > 0 else {
            onStateChange?()
            return .succeeded(message: localization.string(
                "panel.subtitle.empty",
                defaultValue: "废纸篓为空"
            ))
        }

        isEmptying = true
        lastError = nil
        onStateChange?()
        return await finishEmptying()
    }

    private func finishEmptying() async -> ActionExecutionResult {
        do {
            try await emptyItems()
            guard !Task.isCancelled else {
                isEmptying = false
                onStateChange?()
                return .cancelled
            }
            isEmptying = false
            itemCount = 0
            onStateChange?()
            scheduleCountRefreshIfVisible()
            return .succeeded()
        } catch {
            isEmptying = false
            lastError = error
            onStateChange?()
            scheduleCountRefreshIfVisible()
            logger.error("Empty trash failed: \(error)")
            return .failed(message: lastErrorMessage ?? error.localizedDescription)
        }
    }
}

private func runOsascriptStandalone(_ script: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}
