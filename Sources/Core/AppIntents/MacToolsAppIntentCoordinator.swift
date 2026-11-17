import Foundation
import MacToolsAppIntents
import MacToolsPluginKit

enum AppIntentActionIdentifierCodec {
    private static let prefix = "v1."
    private static let maximumEncodedByteCount = 32 * 1_024

    static func encode(_ reference: ActionReference) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(reference) else { return nil }
        return prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ identifier: String) -> ActionReference? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let encoded = String(identifier.dropFirst(prefix.count))
        guard !encoded.isEmpty, encoded.utf8.count <= maximumEncodedByteCount else {
            return nil
        }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingCount))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(ActionReference.self, from: data)
    }
}

@MainActor
enum AppIntentActionEligibility {
    static func isDirectlyEligible(
        _ reference: ActionReference,
        registry: ActionRegistry,
        requireAvailability: Bool
    ) -> Bool {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return false
        }
        guard action.definition.risk == .safe,
              action.definition.capabilities.contains(.background),
              action.definition.capabilities.contains(.automatic),
              registry.portability(of: reference) == .portable,
              registry.exposurePolicy(for: reference, on: .appIntents) == .automatic
        else {
            return false
        }
        return !requireAvailability || registry.availability(for: reference).isAvailable
    }
}

@MainActor
struct MacToolsAppIntentActionCatalog {
    let registry: ActionRegistry

    func actions(includeUnavailable: Bool) -> [MacToolsAppIntentAction] {
        registry.catalogEntries.compactMap { entry in
            guard AppIntentActionEligibility.isDirectlyEligible(
                      entry.reference,
                      registry: registry,
                      requireAvailability: !includeUnavailable
                  ),
                  case let .success(action) = registry.registeredAction(for: entry.reference),
                  let identifier = AppIntentActionIdentifierCodec.encode(entry.reference)
            else {
                return nil
            }
            return MacToolsAppIntentAction(
                id: identifier,
                title: entry.title,
                subtitle: entry.subtitle,
                systemImage: action.definition.systemImage
            )
        }
    }

    func actions(for identifiers: [String]) -> [MacToolsAppIntentAction] {
        identifiers.compactMap { identifier in
            guard let decoded = reference(for: identifier),
                  case let .success(reference) = registry.migrate(decoded),
                  AppIntentActionEligibility.isDirectlyEligible(
                      reference,
                      registry: registry,
                      requireAvailability: false
                  ),
                  case let .success(action) = registry.registeredAction(for: reference)
            else {
                return nil
            }
            guard let matchingEntry = registry.catalogEntries.first(where: { entry in
                guard case let .success(migrated) = registry.migrate(entry.reference) else {
                    return false
                }
                return migrated == reference
            }) else { return nil }
            return MacToolsAppIntentAction(
                id: identifier,
                title: matchingEntry.title,
                subtitle: matchingEntry.subtitle,
                systemImage: action.definition.systemImage
            )
        }
    }

    func contains(_ reference: ActionReference) -> Bool {
        registry.catalogEntries.contains { entry in
            guard case let .success(migrated) = registry.migrate(entry.reference) else {
                return false
            }
            return migrated == reference
        }
    }

    func reference(for identifier: String) -> ActionReference? {
        AppIntentActionIdentifierCodec.decode(identifier)
    }
}

@MainActor
final class MacToolsAppIntentCoordinator {
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let runtime: MacToolsAppIntentRuntime
    private let activityHandler: MacToolsAppIntentRuntime.ActivityHandler?
    private let circuitBreaker: any MacToolsAppIntentCircuitBreaking
    private let refreshShortcutParameters: @MainActor () -> Void
    private var hasBecomeReady = false
    private var publishedActions: [MacToolsAppIntentAction]?

    init(
        registry: ActionRegistry,
        executor: ActionExecutor,
        runtime: MacToolsAppIntentRuntime = .shared,
        activityHandler: MacToolsAppIntentRuntime.ActivityHandler? = nil,
        circuitBreaker: any MacToolsAppIntentCircuitBreaking = MacToolsAppIntentCircuitBreaker.shared,
        refreshShortcutParameters: @escaping @MainActor () -> Void = { MacToolsAppShortcuts.refreshParameters() }
    ) {
        self.registry = registry
        self.executor = executor
        self.runtime = runtime
        self.activityHandler = activityHandler
        self.circuitBreaker = circuitBreaker
        self.refreshShortcutParameters = refreshShortcutParameters
    }

    func beginPreparation() {
        hasBecomeReady = false
        runtime.configure(
            actionProvider: { [weak self] includeUnavailable in
                self?.catalog.actions(includeUnavailable: includeUnavailable) ?? []
            },
            actionExecutor: { [weak self] identifier in
                guard let self else {
                    return .failed(message: FeatureL10n.string("操作不可用。"))
                }
                return await self.execute(identifier: identifier)
            },
            actionResolver: { [weak self] identifiers in
                self?.catalog.actions(for: identifiers) ?? []
            },
            activityHandler: activityHandler
        )
    }

    func actionRegistryDidBecomeReady() {
        guard !hasBecomeReady else { return }
        hasBecomeReady = true
        runtime.markReady()
        refreshShortcutParametersIfActionsChanged()
    }

    func actionCatalogDidChange() {
        guard hasBecomeReady else { return }
        refreshShortcutParametersIfActionsChanged()
    }

    /// Availability is invalidated on every coalesced plugin state change, which can
    /// happen several times a second. linkd rate-limits parameter refreshes, so only
    /// publish when the choices Spotlight and Shortcuts would show actually differ.
    private func refreshShortcutParametersIfActionsChanged() {
        let actions = catalog.actions(includeUnavailable: false)
        guard actions != publishedActions else { return }
        publishedActions = actions
        refreshShortcutParameters()
    }

    var eligibleActionCount: Int {
        catalog.actions(includeUnavailable: false).count
    }

    private var catalog: MacToolsAppIntentActionCatalog {
        MacToolsAppIntentActionCatalog(registry: registry)
    }

    private func execute(identifier: String) async -> MacToolsAppIntentExecutionResult {
        guard let decoded = catalog.reference(for: identifier) else {
            return .failed(message: FeatureL10n.string("找不到对应操作。"))
        }
        let reference: ActionReference
        switch registry.migrate(decoded) {
        case let .success(migrated):
            reference = migrated
        case .failure:
            return .failed(message: FeatureL10n.string("操作提供方已发生变化，请重试。"))
        }
        guard AppIntentActionEligibility.isDirectlyEligible(
            reference,
            registry: registry,
            requireAvailability: false
        ), catalog.contains(reference) else {
            return .failed(message: FeatureL10n.string("操作不可用。"))
        }
        switch await circuitBreaker.admitInvocation(actionIdentifier: reference.key.id) {
        case .admitted:
            break
        case .rateLimited:
            return .failed(message: FeatureL10n.string(
                "短时间内运行的 MacTools 操作过多。为防止循环，已停止执行。"
            ))
        case .unavailable:
            return .failed(message: FeatureL10n.string(
                "无法验证 MacTools 操作的循环保护，请稍后重试。"
            ))
        }
        guard AppIntentActionEligibility.isDirectlyEligible(
            reference,
            registry: registry,
            requireAvailability: false
        ), catalog.contains(reference) else {
            return .failed(message: FeatureL10n.string("操作不可用。"))
        }

        let outcome = await executor.execute(ActionInvocation(
            reference: reference,
            source: .appIntent,
            mode: .background
        ))
        return executionResult(outcome, reference: reference)
    }

    private func executionResult(
        _ outcome: ActionExecutionOutcome,
        reference: ActionReference
    ) -> MacToolsAppIntentExecutionResult {
        switch outcome {
        case let .completed(.succeeded(message)):
            return .succeeded(message: message ?? FeatureL10n.string("操作已完成"))
        case let .completed(.failed(message)):
            return .failed(message: message)
        case .completed(.cancelled):
            return .cancelled
        case let .rejected(rejection):
            return .failed(message: Self.message(for: rejection))
        }
    }

    private static func message(for rejection: ActionExecutionRejection) -> String {
        switch rejection {
        case let .unavailable(reason):
            reason ?? FeatureL10n.string("操作当前不可用。")
        case .backgroundExecutionUnsupported, .foregroundExecutionUnsupported:
            FeatureL10n.string("操作不支持当前执行方式。")
        case .confirmationUnavailable:
            FeatureL10n.string("此操作需要确认，但无法显示确认界面。")
        case .confirmationDenied:
            FeatureL10n.string("操作已取消。")
        case .confirmationTimedOut:
            FeatureL10n.string("确认已超时。")
        case .actionAlreadyRunning:
            FeatureL10n.string("此操作正在运行。")
        case .executionTimedOut:
            FeatureL10n.string("操作超时。")
        case let .providerFailure(message):
            message
        case .unknownAction, .invalidParameters, .providerChanged:
            FeatureL10n.string("操作提供方已发生变化，请重试。")
        case .systemExposureUnavailable, .automaticExecutionUnsupported,
             .confirmationRequiredForAutomaticExecution, .externalInvocationUnavailable:
            FeatureL10n.string("操作不可用。")
        }
    }
}
