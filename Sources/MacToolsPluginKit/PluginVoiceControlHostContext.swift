import Foundation

public struct PluginVoiceProvider: Identifiable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Host-issued capabilities are scoped to one explicit voice session.
public struct PluginVoiceCapability: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case action, query, feature }
    public let id: String
    public let kind: Kind
    public let title: String
    public let pluginTitle: String
    public let description: String
    public let parameters: [ActionParameterDefinition]
    public let requiresConfirmation: Bool

    public init(id: String, kind: Kind, title: String, pluginTitle: String,
                description: String, parameters: [ActionParameterDefinition] = [],
                requiresConfirmation: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.pluginTitle = pluginTitle
        self.description = description; self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum PluginVoiceRequest: Sendable {
    case search(String)
    case perform(capabilityID: String, parameters: ActionParameterSet)
}

public struct PluginVoiceReply: Codable, Sendable {
    public let capabilities: [PluginVoiceCapability]
    public let status: String
    public let message: String?
    /// A bounded JSON object supplied by a query provider, treated as data.
    public let payload: String?

    public init(capabilities: [PluginVoiceCapability] = [], status: String = "ok",
                message: String? = nil, payload: String? = nil) {
        self.capabilities = capabilities; self.status = status; self.message = message; self.payload = payload
    }
}

public struct PluginVoiceQuery: Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let includesPrivateContent: Bool
    public let confirmation: ActionConfirmation?

    public init(id: String, title: String, description: String,
                includesPrivateContent: Bool = false, confirmation: ActionConfirmation? = nil) {
        self.id = id; self.title = title; self.description = description
        self.includesPrivateContent = includesPrivateContent; self.confirmation = confirmation
    }
}

/// Optional bounded state queries; never replace canonical mutations with query methods.
@MainActor
public protocol PluginVoiceQueryProviding: AnyObject {
    var voiceQueries: [PluginVoiceQuery] { get }
    func readVoiceQuery(id: String) async throws -> String
}

/// Providers explicitly opt parameterized definitions into voice discovery.
/// Complete canonical catalog entries remain discoverable without this protocol.
@MainActor
public protocol PluginVoiceParameterizedActionProviding: AnyObject {
    var voiceParameterizedActionIDs: Set<String> { get }
}

/// A voice-session owner may expose only explicitly declared fixed canonical self controls.
/// Native action validation and confirmation remain authoritative.
@MainActor
public protocol PluginVoiceSelfActionProviding: AnyObject {
    var voiceSelfActionIDs: Set<String> { get }
}

@MainActor
public struct PluginVoiceControlHostContext {
    public let providers: () -> [PluginVoiceProvider]
    private let beginHandler: (Set<String>) -> UUID?
    private let endHandler: (UUID) -> Void
    private let requestHandler: (UUID, PluginVoiceRequest) async -> PluginVoiceReply

    public init(providers: @escaping () -> [PluginVoiceProvider] = { [] }, begin: @escaping (Set<String>) -> UUID?, end: @escaping (UUID) -> Void,
                request: @escaping (UUID, PluginVoiceRequest) async -> PluginVoiceReply) {
        self.providers = providers
        beginHandler = begin; endHandler = end; requestHandler = request
    }

    public func beginSession(excludingPluginIDs: Set<String> = []) -> UUID? { beginHandler(excludingPluginIDs) }
    public func endSession(_ id: UUID) { endHandler(id) }
    public func request(_ request: PluginVoiceRequest, sessionID: UUID) async -> PluginVoiceReply {
        await requestHandler(sessionID, request)
    }
}

@MainActor
public protocol PluginVoiceControlHostContextConsuming: AnyObject {
    var voiceControlHostContext: PluginVoiceControlHostContext? { get set }
}
