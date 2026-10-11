import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class EjectDiskPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        EjectDiskPluginProvider(context: context)
    }
}

@MainActor
private struct EjectDiskPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [EjectDiskPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class EjectDiskPlugin: MacToolsPlugin, PluginActionProviding {
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

    private enum ActionID {
        static let ejectAll = "eject-all"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "eject-disk",
            title: localization.string("metadata.title", defaultValue: "推出磁盘"),
            iconName: "eject",
            iconTint: Color(nsColor: .systemGray),
            order: 92,
            defaultDescription: localization.string("metadata.description", defaultValue: "推出所有可移动磁盘")
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let discoverVolumes: @Sendable () async throws -> [EjectableVolume]
    private let ejectVolume: @Sendable (EjectableVolume) async throws -> Void
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EjectDiskPlugin")
    private var isEjecting = false
    private var isDetecting = false
    private var ejectableVolumes: [EjectableVolume] = []
    private var lastErrorMessage: String?
    private var discoveryTask: Task<Void, Never>?
    private var visiblePanelItems: Set<String> = []

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        discoverVolumes: @escaping @Sendable () async throws -> [EjectableVolume] = EjectDiskService.discoverMountedEjectableVolumes,
        ejectVolume: @escaping @Sendable (EjectableVolume) async throws -> Void = EjectDiskService.eject
    ) {
        self.localization = localization
        self.discoverVolumes = discoverVolumes
        self.ejectVolume = ejectVolume
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: { localization.string("panel.button.eject", defaultValue: "推出") }
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: subtitle,
            isOn: false,
            isEnabled: !isDetecting && !isEjecting && !ejectableVolumes.isEmpty,
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
                key: ActionKey(providerID: metadata.id, actionID: ActionID.ejectAll),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "disk", "eject", "volume"],
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: localization.string("panel.button.eject", defaultValue: "推出")
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive],
                executionTimeoutSeconds: 120
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.ejectAll else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return isDetecting || isEjecting
            ? .unavailable(subtitle)
            : .available
    }

    func refresh() {}

    func deactivate(reason _: PluginDeactivationReason) {
        visiblePanelItems.removeAll()
        discoveryTask?.cancel()
        discoveryTask = nil
        isDetecting = false
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "control" || surface == "quick-control" else {
            return
        }
        let wasHidden = visiblePanelItems.isEmpty
        visiblePanelItems.insert(surface)
        if wasHidden { discoverEjectableVolumes() }
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard visiblePanelItems.remove(surface) != nil, visiblePanelItems.isEmpty else {
            return
        }

        discoveryTask?.cancel()
        discoveryTask = nil
        isDetecting = false
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            if controlID == "execute" {
                ejectAllDisks()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.ejectAll else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.performCanonicalEject()
        }
    }

    // MARK: - Private

    private var subtitle: String {
        if isEjecting {
            return localization.string("panel.subtitle.ejecting", defaultValue: "推出中...")
        }
        if isDetecting {
            return localization.string("panel.subtitle.detecting", defaultValue: "正在检测...")
        }
        if ejectableVolumes.isEmpty {
            return localization.string("panel.subtitle.none", defaultValue: "无可推出的磁盘")
        }
        return localization.format(
            "panel.subtitle.countFormat",
            defaultValue: "%d 个可推出的磁盘",
            ejectableVolumes.count
        )
    }

    private func discoverEjectableVolumes() {
        discoveryTask?.cancel()
        isDetecting = true
        lastErrorMessage = nil
        onStateChange?()

        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let volumes = try await self.discoverVolumes()
                guard !Task.isCancelled else { return }

                self.ejectableVolumes = volumes
                self.isDetecting = false
                self.discoveryTask = nil
                self.logger.debug("Found \(volumes.count) ejectable mounted volumes")
                self.onStateChange?()
            } catch {
                guard !Task.isCancelled else { return }

                self.ejectableVolumes = []
                self.isDetecting = false
                self.discoveryTask = nil
                self.lastErrorMessage = error.localizedDescription
                self.logger.error("Failed to discover ejectable disks: \(error.localizedDescription)")
                self.onStateChange?()
            }
        }
    }

    private func ejectAllDisks() {
        guard !isDetecting, !isEjecting, !ejectableVolumes.isEmpty else { return }

        isEjecting = true
        lastErrorMessage = nil
        onStateChange?()

        let volumes = ejectableVolumes

        Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await self.executeEjectAll(volumes)
            self.ejectableVolumes = outcome.failedVolumes
            self.isEjecting = false
            self.lastErrorMessage = outcome.errorMessage
            if let errorMessage = outcome.errorMessage {
                self.logger.error("Failed to eject some disks: \(errorMessage)")
            }
            self.onStateChange?()
        }
    }

    private func executeEjectAll(_ volumes: [EjectableVolume]) async -> EjectOutcome {
        var successCount = 0
        var failedVolumes: [EjectableVolume] = []
        var errorMessages: [String] = []

        for volume in volumes {
            do {
                try await ejectVolume(volume)
                successCount += 1
                logger.info("Successfully ejected volume: \(volume.id)")
            } catch {
                failedVolumes.append(volume)
                errorMessages.append("- \(volume.name): \(error.localizedDescription)")
                logger.error("Failed to eject volume '\(volume.id)': \(error.localizedDescription)")
            }
        }

        let errorMessage = errorMessages.isEmpty
            ? nil
            : localization.format(
                "error.partialFailureFormat",
                defaultValue: "已推出 %d 个磁盘，%d 个失败:\n%@",
                successCount,
                errorMessages.count,
                errorMessages.joined(separator: "\n")
            )
        return EjectOutcome(failedVolumes: failedVolumes, errorMessage: errorMessage)
    }

    private func performCanonicalEject() async -> ActionExecutionResult {
        guard !isDetecting, !isEjecting else {
            return .failed(message: subtitle)
        }

        isDetecting = true
        lastErrorMessage = nil
        onStateChange?()

        let volumes: [EjectableVolume]
        do {
            volumes = try await discoverVolumes()
        } catch {
            isDetecting = false
            lastErrorMessage = error.localizedDescription
            onStateChange?()
            return .failed(message: error.localizedDescription)
        }

        guard !Task.isCancelled else {
            isDetecting = false
            onStateChange?()
            return .cancelled
        }

        isDetecting = false
        ejectableVolumes = volumes
        guard !volumes.isEmpty else {
            onStateChange?()
            return .succeeded(message: localization.string(
                "panel.subtitle.none",
                defaultValue: "无可推出的磁盘"
            ))
        }

        isEjecting = true
        onStateChange?()
        let outcome = await executeEjectAll(volumes)
        ejectableVolumes = outcome.failedVolumes
        isEjecting = false
        lastErrorMessage = outcome.errorMessage
        onStateChange?()

        if Task.isCancelled {
            return .cancelled
        }
        if let errorMessage = outcome.errorMessage {
            return .failed(message: errorMessage)
        }
        return .succeeded()
    }
}

private struct EjectOutcome {
    let failedVolumes: [EjectableVolume]
    let errorMessage: String?
}
