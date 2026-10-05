import Foundation
import MacToolsPluginKit

// MARK: - Fan Preset

struct FanPreset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var strategy: FanControlStrategy
    /// Built-in presets (auto / full-speed) cannot be deleted or renamed.
    let isBuiltIn: Bool

    init(id: String, name: String, strategy: FanControlStrategy, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.strategy = strategy
        self.isBuiltIn = isBuiltIn
    }

    func displayName(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch id {
        case FanPresetBuiltInID.auto:
            return localization.string("preset.auto.name", defaultValue: "自动")
        case FanPresetBuiltInID.fullSpeed:
            return localization.string("preset.fullSpeed.name", defaultValue: "全速")
        default:
            return name
        }
    }
}

enum FanControlStrategy: Codable, Equatable {
    /// Restore macOS automatic fan management.
    case auto
    /// Set all fans to their hardware-reported maximum speed.
    case fullSpeed
    /// Set all fans to a fixed RPM (clamped to hardware limits at write time).
    case fixed(rpm: Int)
}

// MARK: - Built-in Preset IDs

enum FanPresetBuiltInID {
    static let auto = "builtin-auto"
    static let fullSpeed = "builtin-full-speed"
}

// MARK: - Fan Snapshot

struct FanSnapshot: Equatable {
    var fanCount: Int
    var fanSpeeds: [Int]
    var fanMinSpeeds: [Int]
    var fanMaxSpeeds: [Int]
    var cpuTemperature: Double?

    var averageSpeed: Int? {
        guard !fanSpeeds.isEmpty else { return nil }
        return fanSpeeds.reduce(0, +) / fanSpeeds.count
    }

    var globalMaxSpeed: Int {
        fanMaxSpeeds.max() ?? FanRPMLimits.fallbackMax
    }

    static let empty = FanSnapshot(
        fanCount: 0,
        fanSpeeds: [],
        fanMinSpeeds: [],
        fanMaxSpeeds: [],
        cpuTemperature: nil
    )

    func isMeaningfullyEquivalent(
        to other: FanSnapshot,
        rpmTolerance: Int = 10,
        temperatureTolerance: Double = 0.5
    ) -> Bool {
        guard
            fanCount == other.fanCount,
            fanMinSpeeds == other.fanMinSpeeds,
            fanMaxSpeeds == other.fanMaxSpeeds,
            fanSpeeds.count == other.fanSpeeds.count
        else {
            return false
        }

        for (lhs, rhs) in zip(fanSpeeds, other.fanSpeeds) {
            if abs(lhs - rhs) > rpmTolerance {
                return false
            }
        }

        switch (cpuTemperature, other.cpuTemperature) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return abs(lhs - rhs) <= temperatureTolerance
        case (.some, .none), (.none, .some):
            return false
        }
    }
}

// MARK: - RPM Limits

enum FanRPMLimits {
    static let absoluteMin = 500
    static let absoluteMax = 8000
    static let fallbackMin = 1000
    static let fallbackMax = 5200
    static let defaultCustomRPM = 3000
}

// MARK: - Write Error

enum FanHelperInstallFailure {
    case missingAfterInstall
    case authorizationScriptUnavailable
    case systemMessage(String)

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .missingAfterInstall:
            return localization.string(
                "writer.error.helperMissingAfterInstall",
                defaultValue: "安装后仍无法找到组件"
            )
        case .authorizationScriptUnavailable:
            return localization.string(
                "writer.error.authorizationScriptFailed",
                defaultValue: "无法创建授权脚本"
            )
        case .systemMessage(let message):
            return message
        }
    }
}

enum FanWriteFailure {
    case restoreAutoPartial
    case fullSpeedPartial
    case fixedRPMPartial
    case systemMessage(String)

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .restoreAutoPartial:
            return localization.string(
                "writer.error.restoreAutoPartial",
                defaultValue: "部分风扇恢复自动控制失败"
            )
        case .fullSpeedPartial:
            return localization.string(
                "writer.error.fullSpeedPartial",
                defaultValue: "部分风扇设置全速失败"
            )
        case .fixedRPMPartial:
            return localization.string(
                "writer.error.fixedRPMPartial",
                defaultValue: "部分风扇设置目标转速失败"
            )
        case .systemMessage(let message):
            return message
        }
    }
}

enum FanWriteError: Error, LocalizedError {
    case helperNotFound
    case helperInstallFailed(FanHelperInstallFailure)
    case helperVerificationFailed
    case writeFailed(FanWriteFailure)

    var errorDescription: String? {
        localizedDescription()
    }

    func localizedDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .helperNotFound:
            return localization.string(
                "writeError.helperNotFound",
                defaultValue: "未找到内置风扇控制组件。请重新安装风扇控制插件。"
            )
        case .helperInstallFailed(let msg):
            return localization.format(
                "writeError.helperInstallFailed",
                defaultValue: "安装风扇控制组件失败：%@",
                msg.localizedDescription(localization: localization)
            )
        case .helperVerificationFailed:
            return localization.string(
                "writeError.helperVerificationFailed",
                defaultValue: "风扇控制组件校验失败。请重新安装风扇控制插件。"
            )
        case .writeFailed(let msg):
            return localization.format(
                "writeError.writeFailed",
                defaultValue: "写入风扇速度失败：%@",
                msg.localizedDescription(localization: localization)
            )
        }
    }
}

// MARK: - SMC Protocols

protocol FanControlSMCReading: AnyObject {
    @MainActor func readSnapshot() -> FanSnapshot
}

protocol FanControlSMCWriting: AnyObject {
    @MainActor var isHelperAvailable: Bool { get }
    @MainActor var isInstalledHelperAvailable: Bool { get }
    @MainActor @discardableResult
    func apply(strategy: FanControlStrategy, snapshot: FanSnapshot) -> FanWriteError?
}
