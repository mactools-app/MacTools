import CoreGraphics
import Foundation
import MacToolsPluginKit

enum DisplayVolumeBackendKind: Equatable {
    case ddc
}

struct DisplayVolumeDisplay: Identifiable, Equatable {
    let display: DisplayInfo
    let volume: Double
    let isPendingWrite: Bool

    var id: CGDirectDisplayID { display.id }
}

struct DisplayVolumeSnapshot: Equatable {
    let displays: [DisplayVolumeDisplay]
    let errorMessage: String?
}

enum DisplayVolumeWriteResult: Equatable {
    case succeeded
    case failed(message: String)
}

enum DisplayVolumeControllerError: Error, LocalizedError {
    case displayUnavailable(displayID: CGDirectDisplayID)
    case i2cUnavailable(displayName: String)
    case unsupportedReply(displayName: String)
    case ddcWriteFailed(displayName: String)
    case volumeUnavailable(displayName: String)
    case failed(message: String)

    var errorDescription: String? {
        localizedDescription(localization: DisplayVolumeLocalization.fallback)
    }

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .displayUnavailable:
            return localization.string("error.displayUnavailable", defaultValue: "显示器已断开连接")
        case .i2cUnavailable(let displayName):
            return localization.format("error.i2cUnavailableFormat", defaultValue: "%@ 不支持 DDC/CI", displayName)
        case .unsupportedReply(let displayName):
            return localization.format(
                "error.unsupportedReplyFormat",
                defaultValue: "%@ 返回了无效音量数据",
                displayName
            )
        case .ddcWriteFailed(let displayName):
            return localization.format("error.ddcWriteFailedFormat", defaultValue: "%@ DDC 写入失败", displayName)
        case .volumeUnavailable(let displayName):
            return localization.format(
                "error.volumeUnavailableFormat",
                defaultValue: "%@ 当前无法读取音量",
                displayName
            )
        case .failed(let message):
            return message
        }
    }
}

@MainActor
protocol DisplayVolumeControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }

    func refresh()
    func snapshot() -> DisplayVolumeSnapshot
    func setVolume(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    )
    func setVolumeAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID
    ) async -> DisplayVolumeWriteResult
    func cancelOutstandingWrites()
}

extension DisplayVolumeControlling {
    func cancelOutstandingWrites() {}
}

protocol DisplayVolumeBackend: AnyObject, Sendable {
    var kind: DisplayVolumeBackendKind { get }
    var display: DisplayInfo { get set }
    var cachedVolume: Double { get }

    /// Performs hardware I/O and must run on a background worker.
    func readVolume() throws -> Double
    func writeVolume(_ value: Double) throws
    func cleanup()
}

protocol DisplayVolumeBackendBuilding {
    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayVolumeBackend]
    ) -> [CGDirectDisplayID: any DisplayVolumeBackend]

    func fallbackBackend(
        after failedBackend: any DisplayVolumeBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayVolumeBackend]
    ) -> (any DisplayVolumeBackend)?
}

extension DisplayVolumeBackendBuilding {
    func fallbackBackend(
        after failedBackend: any DisplayVolumeBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayVolumeBackend]
    ) -> (any DisplayVolumeBackend)? {
        nil
    }
}
