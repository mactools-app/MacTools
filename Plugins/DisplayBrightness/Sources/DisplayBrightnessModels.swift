import CoreGraphics
import Foundation
import MacToolsPluginKit

enum DisplayBrightnessBackendKind: String, Equatable, Sendable {
    case appleNative
    case ddc
    case gamma
    case shade

    static let shadeMinimumBrightness = 0.08
}

/// Fresh backend data is distinct from the optimistic slider snapshot.
struct DisplayBrightnessObservation: Sendable {
    let value: Double?
    let backend: DisplayBrightnessBackendKind
    let isPendingWrite: Bool
    var isHardwareReadback: Bool {
        value != nil && !isPendingWrite && (backend == .appleNative || backend == .ddc)
    }
}

struct DisplayBrightnessDisplay: Identifiable, Equatable {
    let display: DisplayInfo
    let brightness: Double
    let isPendingWrite: Bool
    var isReady: Bool = true

    var id: CGDirectDisplayID { display.id }
}

struct DisplayBrightnessSnapshot: Equatable {
    let displays: [DisplayBrightnessDisplay]
    let errorMessage: String?
}

enum DisplayBrightnessWriteResult: Equatable {
    case succeeded
    case failed(message: String)
}

/// An exact action can fail while the same backend remains usable by other controls.
enum DisplayBrightnessExactError: Error {
    case unverifiedTarget
    case rangeUnavailable
    case readbackUnavailable
    case mismatch(requested: Double, observed: Double)
    case shadeRange

    func message(localization: PluginLocalization) -> String {
        switch self {
        case .unverifiedTarget:
            localization.string("error.exactUnverifiedTarget", defaultValue: "无法确认显示器的 DDC/CI 控制目标。")
        case .rangeUnavailable:
            localization.string("error.exactRangeUnavailable", defaultValue: "无法读取显示器的亮度范围。")
        case .readbackUnavailable:
            localization.string("voice.unverified", defaultValue: "亮度设置已发送，但未能验证硬件读数。")
        case let .mismatch(requested, observed):
            localization.format("voice.mismatch", defaultValue: "请求 %.0f%%，硬件读回 %.0f%%。", requested * 100, observed * 100)
        case .shadeRange:
            localization.format(
                "error.exactShadeRange",
                defaultValue: "软件调光仅支持 %@ 到 %@ 的亮度。",
                ActionPercentage.label(Int(DisplayBrightnessBackendKind.shadeMinimumBrightness * 100)),
                ActionPercentage.label(100)
            )
        }
    }
}

enum DisplayBrightnessControllerError: Error, LocalizedError {
    case displayUnavailable(displayID: CGDirectDisplayID)
    case brightnessUnavailable(displayName: String)
    case nativeAPINotAvailable
    case genericBrightnessUnavailable
    case i2cUnavailable(displayName: String)
    case unsupportedReply(displayName: String)
    case ddcWriteFailed(displayName: String)
    case softwareBrightnessFailed
    case nativeBrightnessWriteFailed
    case failed(message: String)

    var errorDescription: String? {
        localizedDescription(localization: DisplayBrightnessLocalization.fallback)
    }

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .displayUnavailable:
            return localization.string("error.displayUnavailable", defaultValue: "显示器已断开连接")
        case .brightnessUnavailable(let displayName):
            return localization.format(
                "error.brightnessUnavailableFormat",
                defaultValue: "%@ 当前无法读取亮度",
                displayName
            )
        case .nativeAPINotAvailable:
            return localization.string("error.nativeAPINotAvailable", defaultValue: "系统亮度接口不可用")
        case .genericBrightnessUnavailable:
            return localization.string("error.genericBrightnessUnavailable", defaultValue: "显示器当前无法读取亮度")
        case .i2cUnavailable(let displayName):
            return localization.format("error.i2cUnavailableFormat", defaultValue: "%@ 不支持 DDC/CI", displayName)
        case .unsupportedReply(let displayName):
            return localization.format(
                "error.unsupportedReplyFormat",
                defaultValue: "%@ 返回了无效亮度数据",
                displayName
            )
        case .ddcWriteFailed(let displayName):
            return localization.format("error.ddcWriteFailedFormat", defaultValue: "%@ DDC 写入失败", displayName)
        case .softwareBrightnessFailed:
            return localization.string("error.softwareBrightnessFailed", defaultValue: "软件亮度调节失败")
        case .nativeBrightnessWriteFailed:
            return localization.string("error.nativeBrightnessWriteFailed", defaultValue: "原生亮度写入失败")
        case .failed(let message):
            return message
        }
    }
}

@MainActor
protocol DisplayBrightnessControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }

    func refresh()
    func actionIdentifier(for displayID: CGDirectDisplayID) -> String?
    func exactBrightnessAvailability(_ value: Double, for displayID: CGDirectDisplayID) -> ActionAvailability
    func snapshot() -> DisplayBrightnessSnapshot
    func setBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    )
    func setBrightnessAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID
    ) async -> DisplayBrightnessWriteResult
    func setExactBrightnessAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        identifier: String
    ) async -> DisplayBrightnessWriteResult
    func cancelOutstandingWrites()
    func observeBrightness(for displayID: CGDirectDisplayID) async -> DisplayBrightnessObservation?
}

extension DisplayBrightnessControlling {
    func exactBrightnessAvailability(_ value: Double, for displayID: CGDirectDisplayID) -> ActionAvailability {
        .available
    }

    func setExactBrightnessAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        identifier: String
    ) async -> DisplayBrightnessWriteResult {
        guard actionIdentifier(for: displayID) == identifier, !Task.isCancelled else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }
        return await setBrightnessAndWait(value, for: displayID)
    }

    func cancelOutstandingWrites() {}
    func observeBrightness(for displayID: CGDirectDisplayID) async -> DisplayBrightnessObservation? { nil }
}

protocol DisplayBrightnessBackend: AnyObject, Sendable {
    var kind: DisplayBrightnessBackendKind { get }
    var hasVerifiedDisplayBinding: Bool { get }
    var display: DisplayInfo { get set }

    func readBrightness() throws -> Double
    func writeBrightness(_ value: Double) throws
    func writeExactBrightness(_ value: Double, permit: DisplayActionWritePermit) throws -> Double?
    func cleanup()
}

extension DisplayBrightnessBackend {
    var hasVerifiedDisplayBinding: Bool { true }

    func exactActionError(for value: Double) -> DisplayBrightnessExactError? {
        if !hasVerifiedDisplayBinding { return .unverifiedTarget }
        if kind == .shade, value < DisplayBrightnessBackendKind.shadeMinimumBrightness { return .shadeRange }
        return nil
    }

    func writeExactBrightness(_ value: Double, permit: DisplayActionWritePermit) throws -> Double? {
        guard permit.canWrite else { throw CancellationError() }
        try writeBrightness(value)
        return nil
    }
}

protocol DisplayBrightnessBackendBuilding {
    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend]

    func fallbackBackend(
        after failedBackend: any DisplayBrightnessBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)?
}

extension DisplayBrightnessBackendBuilding {
    func fallbackBackend(
        after failedBackend: any DisplayBrightnessBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        nil
    }
}
