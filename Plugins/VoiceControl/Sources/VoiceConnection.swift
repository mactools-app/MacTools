import Foundation

@MainActor
protocol VoiceConnection: AnyObject {
    var httpStatus: Int? { get }
    func resume()
    func send(_ event: [String: Any]) async throws
    func receive() async throws -> [String: Any]
    func cancel()
}

@MainActor
final class VoiceWebSocketConnection: VoiceConnection {
    private let task: URLSessionWebSocketTask
    init(network: URLSession, request: URLRequest) {
        task = network.webSocketTask(with: request)
        task.maximumMessageSize = 2_000_000
    }
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    func resume() { task.resume() }
    func send(_ event: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let value = String(data: data, encoding: .utf8) else { throw VoiceFailure.protocolError }
        try await task.send(.string(value))
    }
    func receive() async throws -> [String: Any] {
        let data: Data
        switch try await task.receive() {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw VoiceFailure.protocolError
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceFailure.protocolError
        }
        return event
    }
    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

enum VoiceServiceFailure: Error {
    case authentication, quota, rateLimited, modelAccess, connection

    static func classify(_ error: [String: Any]?, httpStatus: Int? = nil) -> Self {
        switch error?["code"] as? String ?? error?["type"] as? String {
        case "invalid_api_key", "authentication_error": return .authentication
        case "insufficient_quota", "billing_hard_limit_reached": return .quota
        case "rate_limit_exceeded", "concurrent_session_limit_exceeded": return .rateLimited
        case "model_not_found", "permission_denied", "unsupported_model": return .modelAccess
        default:
            switch httpStatus {
            case 401: return .authentication
            case 403, 404: return .modelAccess
            case 429: return .rateLimited
            default: return .connection
            }
        }
    }
    var message: String {
        switch self {
        case .authentication: "API 密钥未通过验证，请检查后重新保存。"
        case .quota: "API 额度不足，请检查 OpenAI 账户余额和用量限制。"
        case .rateLimited: "请求过于频繁，请稍后重新开始对话。"
        case .modelAccess: "当前 API 项目无法访问所需模型，请检查权限。"
        case .connection: "连接已中断，请检查网络、API 额度和模型权限后重试"
        }
    }
}
