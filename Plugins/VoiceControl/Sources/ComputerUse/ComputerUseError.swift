import Foundation

enum ComputerUseError: LocalizedError {
    case unavailable(String)
    case invalidTarget
    case staleObservation
    case invalidURL
    case invalidParameters
    case unverified

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidTarget: "Choose one running application by its exact name or bundle identifier."
        case .staleObservation: "The observed window or control has changed. Inspect it again before another action."
        case .invalidURL: "Use a complete HTTP or HTTPS address without embedded credentials."
        case .invalidParameters: "The requested action has invalid or incomplete parameters."
        case .unverified: "The action may have run, but its result could not be verified. Do not retry automatically."
        }
    }
}
