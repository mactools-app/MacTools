import Combine
import Foundation
import MacToolsPluginKit

/// Local button decisions only. Voice/model output cannot change the control mode.
@MainActor
final class VoiceApprovals: ObservableObject {
    @Published private(set) var pending: PluginVoiceConfirmationRequest?
    @Published private(set) var directControlEnabled = false
    var onPresent: ((PluginVoiceConfirmationRequest) -> Void)?
    var onResolve: (() -> Void)?
    private let timeout: Duration
    private var continuation: CheckedContinuation<Bool, Never>?
    private var expiry: Task<Void, Never>?

    init(timeout: Duration = .seconds(45)) { self.timeout = timeout }

    func setDirectControl(_ enabled: Bool) {
        guard directControlEnabled != enabled else { return }
        cancel()
        directControlEnabled = enabled
    }

    func confirm(_ request: PluginVoiceConfirmationRequest) async -> Bool {
        guard pending == nil, !Task.isCancelled else { return false }
        // Setup consent remains an individual button decision in either mode.
        if directControlEnabled && request.allowsDirectControl { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation
                pending = request
                expiry = Task { [weak self, timeout] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resolve(false, requestID: request.id)
                }
                onPresent?(request)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolve(false, requestID: request.id) } }
    }

    func resolve(_ approved: Bool, requestID: UUID) {
        guard pending?.id == requestID else { return }
        let response = continuation
        continuation = nil
        pending = nil
        expiry?.cancel(); expiry = nil
        onResolve?()
        response?.resume(returning: approved)
    }

    func cancel() { if let pending { resolve(false, requestID: pending.id) } }
    func endConversation() { cancel() }
}
