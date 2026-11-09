import AppKit
import CoreGraphics
import Foundation

public struct DisplayInfo: Identifiable, Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltin: Bool
    public let isMain: Bool
    public let vendorNumber: UInt32?
    public let modelNumber: UInt32?
    public let serialNumber: UInt32?

    public init(
        id: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        isMain: Bool,
        vendorNumber: UInt32?,
        modelNumber: UInt32?,
        serialNumber: UInt32?
    ) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }

    public var isAppleDisplay: Bool {
        isBuiltin || supportsAppleNativeBrightness
    }

    public var supportsAppleNativeBrightness: Bool {
        vendorNumber == 0x610
            || name.localizedCaseInsensitiveContains("apple")
            || name.localizedCaseInsensitiveContains("studio display")
            || name.localizedCaseInsensitiveContains("pro display")
            || name.localizedCaseInsensitiveContains("lg ultrafine")
            || name.localizedCaseInsensitiveContains("thunderbolt display")
            || name.localizedCaseInsensitiveContains("led cinema")
            || name.localizedCaseInsensitiveContains("cinema display")
    }
}

public protocol DisplayProviding {
    func listConnectedDisplays() -> [DisplayInfo]
    func screen(for displayID: CGDirectDisplayID) -> NSScreen?
}

public struct SystemDisplayService: DisplayProviding {
    public init() {}

    public func listConnectedDisplays() -> [DisplayInfo] {
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)

        let maxCount = max(activeCount, 16)
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(maxCount))
        CGGetActiveDisplayList(maxCount, &displayIDs, &activeCount)

        return Array(displayIDs.prefix(Int(activeCount))).enumerated().compactMap { index, displayID in
            if CGDisplayIsInMirrorSet(displayID) != 0, CGDisplayIsMain(displayID) == 0 {
                return nil
            }

            let screen = screen(for: displayID)
            let name = screen?.localizedName ?? "Display \(index + 1)"
            let vendorNumber = CGDisplayVendorNumber(displayID)
            let modelNumber = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)

            return DisplayInfo(
                id: displayID,
                name: name,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                isMain: CGDisplayIsMain(displayID) != 0,
                vendorNumber: vendorNumber == 0 ? nil : vendorNumber,
                modelNumber: modelNumber == 0 ? nil : modelNumber,
                serialNumber: serialNumber == 0 ? nil : serialNumber
            )
        }
    }

    public func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        })
    }
}
