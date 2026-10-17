import Foundation

struct AutoInputSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum AutoInputHUDSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }
}

enum AutoInputHUDPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case above
    case below
    case screenCenter
    case atPointer

    var id: String { rawValue }

    func isAvailable(isInteractive: Bool) -> Bool {
        self != .atPointer || isInteractive
    }
}

enum AutoInputHUDReminderLimits {
    static let minimumIntervalSeconds = 5
    static let maximumIntervalSeconds = 300
    static let defaultIntervalSeconds = 60
    static let minimumAppSwitchCount = 1
    static let maximumAppSwitchCount = 10
    static let defaultAppSwitchCount = 3

    static func normalizedIntervalSeconds(_ value: Int) -> Int {
        guard (minimumIntervalSeconds...maximumIntervalSeconds).contains(value) else {
            return defaultIntervalSeconds
        }
        return value
    }

    static func normalizedAppSwitchCount(_ value: Int) -> Int {
        guard (minimumAppSwitchCount...maximumAppSwitchCount).contains(value) else {
            return defaultAppSwitchCount
        }
        return value
    }
}

struct AutoInputHUDConfiguration: Equatable, Sendable {
    let size: AutoInputHUDSize
    let position: AutoInputHUDPosition
    let isInteractive: Bool

    init(
        size: AutoInputHUDSize,
        position: AutoInputHUDPosition,
        isInteractive: Bool = false
    ) {
        self.size = size
        self.position = position
        self.isInteractive = isInteractive
    }

    var effectivePosition: AutoInputHUDPosition {
        position.isAvailable(isInteractive: isInteractive) ? position : .automatic
    }
}

struct AutoInputApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let bundleURL: URL?
    let processIdentifier: pid_t?

    init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL?,
        processIdentifier: pid_t? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.processIdentifier = processIdentifier
    }
}

enum AutoInputKeyboardMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Keep the MacBook top row as configured in System Settings.
    case system
    /// Treat the top row as standard F1–F12 function keys.
    case standardFunctionKeys
    /// Keep the MacBook special functions (brightness, volume, and so on).
    case mediaShortcuts

    var id: String { rawValue }
}

struct AutoInputRule: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    var displayName: String
    var bundleURLString: String?
    var inputSourceID: String
    var keyboardMode: AutoInputKeyboardMode

    var bundleURL: URL? {
        bundleURLString.flatMap(URL.init(string:))
    }

    init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL?,
        inputSourceID: String,
        keyboardMode: AutoInputKeyboardMode = .system
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURLString = bundleURL?.absoluteString
        self.inputSourceID = inputSourceID
        self.keyboardMode = keyboardMode
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case displayName
        case bundleURLString
        case inputSourceID
        case keyboardMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleURLString = try container.decodeIfPresent(String.self, forKey: .bundleURLString)
        inputSourceID = try container.decode(String.self, forKey: .inputSourceID)
        // Rules persisted before keyboard modes existed keep following System Settings.
        keyboardMode = try container.decodeIfPresent(
            AutoInputKeyboardMode.self,
            forKey: .keyboardMode
        ) ?? .system
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(bundleURLString, forKey: .bundleURLString)
        try container.encode(inputSourceID, forKey: .inputSourceID)
        try container.encode(keyboardMode, forKey: .keyboardMode)
    }
}

enum AutoInputSwitchReason: Equatable {
    case fixedRule
    case remembered
}

struct AutoInputTarget: Equatable {
    let source: AutoInputSource
    let reason: AutoInputSwitchReason
}
