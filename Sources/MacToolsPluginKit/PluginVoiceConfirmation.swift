import Foundation

/// A host-prepared approval for one concrete operation. Introduced in host 2.2.4.
public struct PluginVoiceConfirmationRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let message: String
    public let confirmButtonTitle: String
    /// False for setup/permission changes that always need a local button decision.
    public let allowsDirectControl: Bool

    public init(id: UUID = UUID(), title: String, message: String, confirmButtonTitle: String,
                allowsDirectControl: Bool) {
        self.id = id; self.title = title; self.message = message
        self.confirmButtonTitle = confirmButtonTitle; self.allowsDirectControl = allowsDirectControl
    }
}

/// Optional companion contract; no released voice-context layout or witness table changes.
/// Cancellation, dismissal and a replaced session must decline a pending request.
@MainActor
public protocol PluginVoiceConfirmationPresenting: AnyObject {
    func confirmVoiceAction(_ request: PluginVoiceConfirmationRequest) async -> Bool
}
