import Foundation

/// An optional semantic function name for an already exposed canonical voice action. Added in host 2.2.4.
public struct PluginVoiceFunction: Equatable, Sendable {
    public let actionID: String
    public let name: String
    public init(actionID: String, name: String) { self.actionID = actionID; self.name = name }
    public var isValid: Bool {
        !actionID.isEmpty && actionID.utf8.count <= 128 && !name.isEmpty && name.utf8.count <= 64
            && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            && name.utf8.first.map { (97...122).contains($0) || $0 == 95 } == true
    }
}

/// Names improve tool selection; they never expose an otherwise unavailable action or grant authority.
/// Discovery transports validated names in its JSON payload without changing released capability layouts.
@MainActor
public protocol PluginVoiceFunctionProviding: AnyObject {
    var voiceFunctions: [PluginVoiceFunction] { get }
}
