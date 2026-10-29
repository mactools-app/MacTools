import Foundation
import MacToolsPluginKit

/// A voice session can invoke only capabilities it discovered from currently loaded providers.
@MainActor
final class VoiceControlRouter {
    private struct Grant {
        let owner: String
        let allowedPluginIDs: Set<String>
        let expires: ContinuousClock.Instant
        var issued: [String: Binding] = [:]
    }
    private struct Binding {
        enum Operation {
            case action(ActionReference, ActionDefinition, parameterized: Bool)
            case query(PluginVoiceQuery)
            case feature
        }
        let pluginID: String
        let identity: ObjectIdentifier
        let operation: Operation
    }
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let confirmation: any ActionConfirmationRequesting
    private let plugins: () -> [any MacToolsPlugin]
    private let openFeature: (String) -> Void
    private var grants: [UUID: Grant] = [:]
    private var operations: [UUID: (UUID, Task<PluginVoiceReply, Never>)] = [:]
    private let surface = ActionExposureSurface(rawValue: "voice-control")

    init(registry: ActionRegistry, executor: ActionExecutor,
         confirmation: any ActionConfirmationRequesting,
         plugins: @escaping () -> [any MacToolsPlugin], openFeature: @escaping (String) -> Void) {
        self.registry = registry; self.executor = executor; self.confirmation = confirmation
        self.plugins = plugins; self.openFeature = openFeature
    }

    func context(owner: String) -> PluginVoiceControlHostContext {
        PluginVoiceControlHostContext(providers: { [weak self] in
            self?.plugins().filter { $0.metadata.id != owner }.map {
                PluginVoiceProvider(id: $0.metadata.id, title: $0.metadata.title)
            } ?? []
        }, begin: { [weak self] excluded in
            guard let self, owner == "voice-control" else { return nil }
            self.revoke(owner: owner)
            let id = UUID()
            let allowed = Set(self.plugins().map(\.metadata.id)).subtracting(excluded).subtracting([owner])
            self.grants[id] = Grant(owner: owner, allowedPluginIDs: allowed,
                                    expires: .now.advanced(by: .seconds(600)))
            return id
        }, end: { [weak self] id in
            guard self?.grants[id]?.owner == owner else { return }
            self?.end(id)
        }, request: { [weak self] id, request in
            guard let self, self.grants[id]?.owner == owner else { return .init(status: "sessionEnded") }
            let operationID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return PluginVoiceReply(status: "sessionEnded") }
                return await self.route(request, sessionID: id)
            }
            self.operations[operationID] = (id, task)
            defer { self.operations[operationID] = nil }
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        })
    }

    func revoke(owner: String) {
        for id in grants.keys.filter({ grants[$0]?.owner == owner }) { end(id) }
    }

    private func end(_ id: UUID) {
        grants[id] = nil
        for (_, operation) in operations where operation.0 == id { operation.1.cancel() }
    }

    private func valid(_ id: UUID) -> Bool {
        guard let grant = grants[id] else { return false }
        return .now < grant.expires && !Task.isCancelled
    }

    private func route(_ request: PluginVoiceRequest, sessionID: UUID) async -> PluginVoiceReply {
        guard valid(sessionID) else { return .init(status: "sessionEnded") }
        switch request {
        case let .search(query): return discover(query, sessionID: sessionID)
        case let .perform(id, parameters):
            guard let binding = grants[sessionID]?.issued[id],
                  let plugin = plugins().first(where: { $0.metadata.id == binding.pluginID }),
                  ObjectIdentifier(plugin) == binding.identity else { return .init(status: "staleCapability") }
            switch binding.operation {
            case let .action(reference, expected, parameterized):
                guard registry.definition(for: reference.key) == expected else { return .init(status: "staleCapability") }
                guard parameterized
                    ? (plugin as? any PluginVoiceParameterizedActionProviding)?.voiceParameterizedActionIDs.contains(reference.key.actionID) == true
                    : registry.catalogEntries.contains(where: { $0.reference == reference }) else { return .init(status: "staleCapability") }
                guard parameterized || parameters.entries.isEmpty else { return .init(status: "invalidParameters") }
                let target = parameterized
                    ? ActionReference(key: reference.key, schemaVersion: reference.schemaVersion, parameters: parameters)
                    : reference
                guard registry.exposurePolicy(for: target, on: surface) != .excluded else { return .init(status: "unavailable") }
                let result = await executor.execute(ActionInvocation(reference: target, source: .manual, mode: .foreground))
                guard valid(sessionID) else { return .init(status: "sessionEnded") }
                switch result {
                case let .completed(.succeeded(message)): return .init(message: message)
                case .completed(.cancelled): return .init(status: "cancelled")
                case let .completed(.failed(message)): return .init(status: "failedOrUncertain", message: message)
                case .rejected: return .init(status: "unavailable", message: "The host rejected this action. Rediscover or clarify; do not retry a write.")
                }
            case let .query(expected):
                let queryID = expected.id
                guard parameters.entries.isEmpty,
                      let provider = plugin as? any PluginVoiceQueryProviding,
                      let query = provider.voiceQueries.first(where: { $0.id == queryID }), query == expected else { return .init(status: "unavailable") }
                if query.includesPrivateContent && query.confirmation == nil { return .init(status: "permissionRequired") }
                if let prompt = query.confirmation {
                    let approved = await confirmation.confirm(.init(
                        reference: .init(key: .init(providerID: binding.pluginID, actionID: query.id)),
                        confirmation: prompt, source: .manual))
                    guard approved, valid(sessionID) else { return .init(status: "cancelled") }
                }
                guard valid(sessionID),
                      provider.voiceQueries.first(where: { $0.id == queryID }) == expected,
                      plugins().contains(where: { $0.metadata.id == binding.pluginID && ObjectIdentifier($0) == binding.identity }) else {
                    return .init(status: "staleCapability")
                }
                do {
                    let payload = try await provider.readVoiceQuery(id: queryID)
                    guard valid(sessionID),
                          plugins().contains(where: { $0.metadata.id == binding.pluginID && ObjectIdentifier($0) == binding.identity }) else {
                        return .init(status: "sessionEnded")
                    }
                    guard payload.utf8.count <= 32_768,
                          (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil else { return .init(status: "invalidQueryResult") }
                    return .init(payload: payload)
                } catch { return .init(status: "unavailable") }
            case .feature:
                guard parameters.entries.isEmpty else { return .init(status: "invalidParameters") }
                openFeature(binding.pluginID)
                return .init(message: "Opened the feature. Any review or selection must be completed in its native interface.")
            }
        }
    }

    private func discover(_ query: String, sessionID: UUID) -> PluginVoiceReply {
        guard query.utf8.count <= 256, let grant = grants[sessionID] else { return .init(status: "invalidRequest") }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var candidates: [(PluginVoiceCapability, Binding, Int)] = []
        func add(_ plugin: any MacToolsPlugin, kind: PluginVoiceCapability.Kind,
                 title: String, description: String, parameters: [ActionParameterDefinition] = [],
                 confirm: Bool = false, operation: Binding.Operation) {
            let text = "\(title) \(plugin.metadata.title) \(description) \(plugin.metadata.id)".lowercased()
            let score = terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            guard terms.isEmpty || score > 0 else { return }
            let capability = PluginVoiceCapability(id: UUID().uuidString, kind: kind, title: title,
                pluginTitle: plugin.metadata.title, description: description,
                parameters: parameters, requiresConfirmation: confirm)
            candidates.append((capability, Binding(pluginID: plugin.metadata.id,
                identity: ObjectIdentifier(plugin), operation: operation), score))
        }
        for plugin in plugins() where grant.allowedPluginIDs.contains(plugin.metadata.id) {
            let pluginID = plugin.metadata.id
            add(plugin, kind: .feature, title: plugin.metadata.title,
                description: plugin.metadata.defaultDescription ?? "", operation: .feature)
            for entry in registry.catalogEntries where entry.reference.key.providerID == pluginID {
                guard let definition = registry.definition(for: entry.reference.key),
                      registry.exposurePolicy(for: entry.reference, on: surface) != .excluded else { continue }
                add(plugin, kind: .action, title: entry.title,
                    description: definition.description + " " + definition.keywords.joined(separator: " "),
                    confirm: definition.confirmation != nil || definition.risk == .confirmationRequired,
                    operation: .action(entry.reference, definition, parameterized: false))
            }
            if let provider = plugin as? any PluginVoiceParameterizedActionProviding,
               let actionProvider = plugin as? any PluginActionProviding {
                for definition in actionProvider.actionDefinitions where provider.voiceParameterizedActionIDs.contains(definition.key.actionID)
                    && definition.key.providerID == pluginID {
                    let reference = ActionReference(key: definition.key, schemaVersion: definition.parameterSchemaVersion)
                    guard registry.definition(for: definition.key) == definition,
                          registry.exposurePolicy(for: reference, on: surface) != .excluded else { continue }
                    add(plugin, kind: .action, title: definition.title,
                        description: definition.description + " " + definition.keywords.joined(separator: " "),
                        parameters: definition.parameters,
                        confirm: definition.confirmation != nil || definition.risk == .confirmationRequired,
                        operation: .action(reference, definition, parameterized: true))
                }
            }
            if let provider = plugin as? any PluginVoiceQueryProviding {
                for query in provider.voiceQueries {
                    add(plugin, kind: .query, title: query.title, description: query.description,
                        confirm: query.includesPrivateContent || query.confirmation != nil, operation: .query(query))
                }
            }
        }
        let selected = candidates.sorted { left, right in
            if left.2 != right.2 { return left.2 > right.2 }
            let order: [PluginVoiceCapability.Kind] = [.action, .query, .feature]
            if left.0.kind != right.0.kind { return order.firstIndex(of: left.0.kind)! < order.firstIndex(of: right.0.kind)! }
            return left.0.title.localizedStandardCompare(right.0.title) == .orderedAscending
        }.prefix(25)
        guard grant.issued.count + selected.count <= 1_024 else { return .init(status: "discoveryLimit") }
        for (capability, binding, _) in selected { grants[sessionID]?.issued[capability.id] = binding }
        return .init(capabilities: selected.map(\.0))
    }
}
