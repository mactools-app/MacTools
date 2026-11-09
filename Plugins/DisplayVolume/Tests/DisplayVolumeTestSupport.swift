import CoreGraphics
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayVolumePlugin

func makeVolumeTestDisplay(
    id: CGDirectDisplayID,
    name: String,
    isBuiltin: Bool = false,
    isMain: Bool = false,
    vendorNumber: UInt32? = nil,
    modelNumber: UInt32? = nil,
    serialNumber: UInt32? = nil
) -> DisplayInfo {
    DisplayInfo(
        id: id,
        name: name,
        isBuiltin: isBuiltin,
        isMain: isMain,
        vendorNumber: vendorNumber,
        modelNumber: modelNumber,
        serialNumber: serialNumber
    )
}

func makeVolumeDisplay(
    id: CGDirectDisplayID,
    name: String,
    volume: Double,
    vendorNumber: UInt32? = nil,
    modelNumber: UInt32? = nil,
    serialNumber: UInt32? = nil
) -> DisplayVolumeDisplay {
    DisplayVolumeDisplay(
        display: makeVolumeTestDisplay(
            id: id,
            name: name,
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        ),
        volume: volume,
        isPendingWrite: false
    )
}

@MainActor
final class MockDisplayVolumeController: DisplayVolumeControlling {
    struct VolumeWrite: Equatable {
        let value: Double
        let displayID: CGDirectDisplayID
        let phase: PluginPanelAction.SliderPhase
    }

    var onStateChange: (() -> Void)?
    var snapshotValue = DisplayVolumeSnapshot(displays: [], errorMessage: nil)
    var writeResults: [CGDirectDisplayID: DisplayVolumeWriteResult] = [:]
    private(set) var volumeWrites: [VolumeWrite] = []
    private(set) var cancelOutstandingWritesCount = 0

    func refresh() {}

    func snapshot() -> DisplayVolumeSnapshot {
        snapshotValue
    }

    func setVolume(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    ) {
        volumeWrites.append(VolumeWrite(value: value, displayID: displayID, phase: phase))
        snapshotValue = DisplayVolumeSnapshot(
            displays: snapshotValue.displays.map { display in
                guard display.id == displayID else { return display }
                return DisplayVolumeDisplay(
                    display: display.display,
                    volume: min(max(value, 0), 1),
                    isPendingWrite: phase != .ended
                )
            },
            errorMessage: snapshotValue.errorMessage
        )
    }

    func setVolumeAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID
    ) async -> DisplayVolumeWriteResult {
        setVolume(value, for: displayID, phase: .ended)
        return writeResults[displayID] ?? .succeeded
    }

    func cancelOutstandingWrites() {
        cancelOutstandingWritesCount += 1
    }
}

@MainActor
final class DisplayVolumeMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
