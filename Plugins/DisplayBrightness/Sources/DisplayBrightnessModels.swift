import CoreGraphics
import Foundation
import MacToolsPluginKit

enum DisplayBrightnessBackendKind: Equatable {
    case appleNative
    case ddc
    case gamma
    case shade
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
    func cancelOutstandingWrites()
}

extension DisplayBrightnessControlling {
    func cancelOutstandingWrites() {}
}

protocol DisplayBrightnessBackend: AnyObject, Sendable {
    var kind: DisplayBrightnessBackendKind { get }
    var display: DisplayInfo { get set }

    func readBrightness() throws -> Double
    func writeBrightness(_ value: Double) throws
    func cleanup()
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
