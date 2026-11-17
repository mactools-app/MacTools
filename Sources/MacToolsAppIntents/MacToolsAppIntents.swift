@preconcurrency import AppIntents
import Foundation

public struct MacToolsAppIntentsPackage: AppIntentsPackage {
    public init() {}
}

public struct MacToolsAppIntentAction: Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }
}

public enum MacToolsAppIntentExecutionResult: Equatable, Sendable {
    case succeeded(message: String)
    case failed(message: String)
    case cancelled
}

@MainActor
public final class MacToolsAppIntentRuntime {
    public typealias ActionProvider = @MainActor @Sendable (
        _ includeUnavailable: Bool
    ) -> [MacToolsAppIntentAction]
    public typealias ActionExecutor = @MainActor @Sendable (
        _ identifier: String
    ) async -> MacToolsAppIntentExecutionResult
    public typealias ActionResolver = @MainActor @Sendable (
        _ identifiers: [String]
    ) -> [MacToolsAppIntentAction]
    public typealias ActivityHandler = @MainActor @Sendable () -> Void

    public static let shared = MacToolsAppIntentRuntime()

    private var actionProvider: ActionProvider?
    private var actionExecutor: ActionExecutor?
    private var actionResolver: ActionResolver?
    private var activityHandler: ActivityHandler?
    private var hasPendingActivity = false
    private var isReady = false
    private var readinessWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func configure(
        actionProvider: @escaping ActionProvider,
        actionExecutor: @escaping ActionExecutor,
        actionResolver: ActionResolver? = nil,
        activityHandler: ActivityHandler? = nil
    ) {
        self.actionProvider = actionProvider
        self.actionExecutor = actionExecutor
        self.actionResolver = actionResolver
        self.activityHandler = activityHandler
        isReady = false
        if hasPendingActivity, let activityHandler {
            hasPendingActivity = false
            activityHandler()
        }
    }

    public func markReady() {
        guard !isReady else { return }
        isReady = true
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    public func actions(includeUnavailable: Bool) async -> [MacToolsAppIntentAction] {
        // Parameter lookups from Spotlight or Shortcuts also reopen the app.
        noteActivity()
        await waitUntilReady()
        return actionProvider?(includeUnavailable) ?? []
    }

    public func actions(for identifiers: [String]) async -> [MacToolsAppIntentAction] {
        noteActivity()
        await waitUntilReady()
        return actionResolver?(identifiers) ?? []
    }

    public func execute(identifier: String) async -> MacToolsAppIntentExecutionResult {
        noteActivity()
        await waitUntilReady()
        guard let actionExecutor else {
            return .failed(message: AppIntentL10n.runtimeUnavailable)
        }
        return await actionExecutor(identifier)
    }

    private func noteActivity() {
        guard let activityHandler else {
            hasPendingActivity = true
            return
        }
        activityHandler()
    }

    private func waitUntilReady() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            if isReady {
                continuation.resume()
            } else {
                readinessWaiters.append(continuation)
            }
        }
    }
}

public struct MacToolsActionEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "MacTools 操作"
    )
    public static let defaultQuery = MacToolsActionQuery()

    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String

    public init(action: MacToolsAppIntentAction) {
        id = action.id
        title = action.title
        subtitle = action.subtitle
        systemImage = action.systemImage
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" },
            image: DisplayRepresentation.Image(systemName: systemImage)
        )
    }
}

public struct MacToolsActionQuery: EntityQuery, Sendable {
    public init() {}

    public func entities(for identifiers: [MacToolsActionEntity.ID]) async throws
        -> [MacToolsActionEntity]
    {
        await MacToolsAppIntentRuntime.shared.actions(for: identifiers)
            .map(MacToolsActionEntity.init)
    }

    public func suggestedEntities() async throws -> [MacToolsActionEntity] {
        await MacToolsAppIntentRuntime.shared.actions(includeUnavailable: false)
            .map(MacToolsActionEntity.init)
    }
}

public struct RunMacToolsActionIntent: AppIntent {
    public static let title: LocalizedStringResource = "运行 MacTools 操作"
    public static let description = IntentDescription(
        "运行当前可用且适合自动化的 MacTools 或插件操作。"
    )
    public static let openAppWhenRun = false

    @Parameter(title: "操作")
    public var action: MacToolsActionEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("运行 \(\.$action)")
    }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await MacToolsAppIntentRuntime.shared.execute(identifier: action.id) {
        case let .succeeded(message):
            return .result(dialog: IntentDialog("\(message)"))
        case let .failed(message):
            throw MacToolsAppIntentError(message: message)
        case .cancelled:
            throw MacToolsAppIntentError(message: AppIntentL10n.cancelled)
        }
    }
}

public struct MacToolsAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunMacToolsActionIntent(),
            phrases: [
                "用 \(.applicationName) 运行操作",
            ],
            shortTitle: "运行操作",
            systemImageName: "bolt.circle"
        )
    }

    public static var shortcutTileColor: ShortcutTileColor { .orange }

    public static func refreshParameters() {
        updateAppShortcutParameters()
    }
}

private struct MacToolsAppIntentError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private enum AppIntentL10n {
    private final class BundleToken {}

    static let runtimeUnavailable = String(
        localized: "app-intents.error.runtime-unavailable",
        defaultValue: "MacTools 尚未准备好运行此操作。",
        bundle: Bundle(for: BundleToken.self)
    )
    static let cancelled = String(
        localized: "app-intents.error.cancelled",
        defaultValue: "操作已取消。",
        bundle: Bundle(for: BundleToken.self)
    )
}
