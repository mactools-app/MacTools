import Foundation

/// A host-prepared approval for one concrete operation. Introduced in host 2.2.3.
public struct PluginVoiceConfirmationRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let message: String
    public let confirmButtonTitle: String
    public let allowsSpokenConfirmation: Bool

    public init(id: UUID = UUID(), title: String, message: String, confirmButtonTitle: String,
                allowsSpokenConfirmation: Bool) {
        self.id = id; self.title = title; self.message = message
        self.confirmButtonTitle = confirmButtonTitle; self.allowsSpokenConfirmation = allowsSpokenConfirmation
    }
}

/// Optional companion contract; no released voice-context layout or witness table changes.
/// Cancellation, dismissal and a replaced session must decline a pending request.
@MainActor
public protocol PluginVoiceConfirmationPresenting: AnyObject {
    func confirmVoiceAction(_ request: PluginVoiceConfirmationRequest) async -> Bool
}
