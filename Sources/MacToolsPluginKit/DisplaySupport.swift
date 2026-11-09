import AppKit
import CoreGraphics
import Foundation
import os

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

/// Serializes DDC transactions from plugins that share a monitor's request and reply channel.
public enum DisplayDDCTransaction {
    private static let queue = DispatchQueue(label: "MacTools.DisplayDDC")

    public static func perform<Result>(_ transaction: () throws -> Result) rethrows -> Result {
        try queue.sync(execute: transaction)
    }
}

/// Identifies the display in a saved action independently of its current Core Graphics ID.
public enum DisplayActionTarget {
    public static let parameterID = "display"

    public static func catalogEntries(
        for displays: [DisplayInfo],
        definition: ActionDefinition,
        identifier: (CGDirectDisplayID) -> String?
    ) -> [ActionCatalogEntry] {
        let identified = displays.compactMap { display in
            identifier(display.id).map { (id: $0, display: display) }
        }
        let targetsByID = Dictionary(grouping: identified, by: \.id)
        let targetsByName = Dictionary(grouping: identified, by: { $0.display.name })
        return identified.compactMap { target in
            guard targetsByID[target.id]?.count == 1,
                  let parameters = try? ActionParameterSet([
                      parameterID: .string(target.id),
                      ActionPercentage.parameterID: .integer(Int64(ActionPercentage.defaultValue)),
                  ]) else { return nil }
            let name: String
            if let sameName = targetsByName[target.display.name], sameName.count > 1,
               let index = sameName.firstIndex(where: { $0.display.id == target.display.id }) {
                name = "\(target.display.name) (\(index + 1))"
            } else {
                name = target.display.name
            }
            let reference = ActionReference(key: definition.key, parameters: parameters)
            return ActionCatalogEntry(
                reference: reference,
                title: ActionPercentage.title(definition.title, target: name, value: ActionPercentage.defaultValue),
                subtitle: name
            )
        }
    }

    public static func resolve(
        _ reference: ActionReference,
        in displays: [DisplayInfo],
        identifier: (CGDirectDisplayID) -> String?
    ) -> (display: DisplayInfo, percent: Int, identifier: String)? {
        guard case let .string(target)? = reference.parameters[parameterID],
              let percent = ActionPercentage.value(in: reference) else { return nil }
        let matches = displays.filter { identifier($0.id) == target }
        guard matches.count == 1, let display = matches.first else { return nil }
        return (display, percent, target)
    }

    /// Best-effort continuity for interactive controls when macOS has no saved-action UUID.
    public static func sameDisplayWithoutUUID(_ previous: DisplayInfo, _ current: DisplayInfo) -> Bool {
        previous.id == current.id && previous.name == current.name
            && previous.isBuiltin == current.isBuiltin && previous.vendorNumber == current.vendorNumber
            && previous.modelNumber == current.modelNumber && previous.serialNumber == current.serialNumber
    }

    public static func identifier(for displayID: CGDirectDisplayID) -> String? {
        guard CGDisplayIsActive(displayID) != 0 else { return nil }
        if CGDisplayIsBuiltin(displayID) != 0 { return "builtin" }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return "display-uuid-\((CFUUIDCreateString(nil, uuid) as String).uppercased())"
    }
}

/// A saved write must still target the same active display when it reaches hardware I/O.
public final class DisplayActionWritePermit: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let matchesDisplay: @Sendable () -> Bool

    public init(matchesDisplay: @escaping @Sendable () -> Bool) {
        self.matchesDisplay = matchesDisplay
    }

    public var isTargetCurrent: Bool { matchesDisplay() }

    public var canWrite: Bool {
        isTargetCurrent && !cancelled.withLock { $0 }
    }

    public func cancel() {
        cancelled.withLock { $0 = true }
    }
}
