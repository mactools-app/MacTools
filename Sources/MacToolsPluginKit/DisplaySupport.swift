import AppKit
import CoreGraphics
import CryptoKit
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

/// The nonzero EDID fields used to corroborate a discovered DDC service.
public struct DisplayDDCIdentity: Hashable, Sendable {
    private static let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    public static var bindingGeneration: UInt64 { generation.withLock { $0 } }

    /// Invalidates cached DDC bindings before the host's debounced refresh.
    public static func invalidateBindings() {
        generation.withLock { $0 &+= 1 }
    }

    private let vendor: UInt32
    private let product: UInt32
    private let serial: UInt32

    public init?(vendor: UInt32?, product: UInt32?, serial: UInt32?) {
        guard let vendor, vendor != 0, let product, product != 0, let serial, serial != 0 else { return nil }
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }

    public static func onlineIdentities() -> [CGDirectDisplayID: Self] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = Array(repeating: CGDirectDisplayID(), count: max(Int(count) + 1, 16))
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success,
              Int(count) < ids.count else { return [:] }
        return ids.prefix(Int(count)).reduce(into: [:]) { identities, id in
            identities[id] = Self(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id),
                                  serial: CGDisplaySerialNumber(id))
        }
    }

    public func isUniqueOnline(
        for displayID: CGDirectDisplayID,
        in identities: [CGDirectDisplayID: Self]
    ) -> Bool {
        identities[displayID] == self && !identities.contains { $0.key != displayID && $0.value == self }
    }

    public static func uniqueMatches(
        for displays: [DisplayInfo],
        candidates: [Self?],
        onlineIdentities: [CGDirectDisplayID: Self]
    ) -> [CGDirectDisplayID: Int] {
        let listed = displays.filter { !$0.isBuiltin }.compactMap { display in
            Self(vendor: display.vendorNumber, product: display.modelNumber, serial: display.serialNumber)
                .map { (id: display.id, identity: $0) }
        }
        var matches: [CGDirectDisplayID: Int] = [:]
        for (id, identity) in listed {
            guard identity.isUniqueOnline(for: id, in: onlineIdentities),
                  listed.filter({ $0.identity == identity }).count == 1 else { continue }
            let indices = candidates.indices.filter { candidates[$0] == identity }
            if indices.count == 1 { matches[id] = indices.first }
        }
        return matches
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
        return identified.compactMap { target in
            guard targetsByID[target.id]?.count == 1,
                  let parameters = try? ActionParameterSet([
                      parameterID: .string(target.id),
                      ActionPercentage.parameterID: .integer(Int64(ActionPercentage.defaultValue)),
                  ]) else { return nil }
            let name: String
            if target.display.isBuiltin {
                name = target.display.name
            } else {
                // The short code stays with this target across inventory changes without exposing its identifier.
                let code = SHA256.hash(data: Data(target.id.utf8)).prefix(5)
                    .map { String(format: "%02X", $0) }.joined()
                name = "\(target.display.name) (\(code))"
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
        return persistentIdentifier(for: displayID)
    }

    public static func onlineIdentifier(for displayID: CGDirectDisplayID) -> String? {
        guard CGDisplayIsOnline(displayID) != 0 else { return nil }
        return persistentIdentifier(for: displayID)
    }

    private static func persistentIdentifier(for displayID: CGDirectDisplayID) -> String? {
        if CGDisplayIsBuiltin(displayID) != 0 { return "builtin" }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return "display-uuid-\((CFUUIDCreateString(nil, uuid) as String).uppercased())"
    }
}

/// A saved write must still target the same active display when it reaches hardware I/O.
public final class DisplayActionWritePermit: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var didAttemptWrite = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let matchesDisplay: @Sendable () -> Bool

    public init(matchesDisplay: @escaping @Sendable () -> Bool) {
        self.matchesDisplay = matchesDisplay
    }

    public var isTargetCurrent: Bool { matchesDisplay() }

    public var didAttemptWrite: Bool { state.withLock { $0.didAttemptWrite } }

    public var canWrite: Bool {
        isTargetCurrent && !state.withLock { $0.cancelled }
    }

    /// Call immediately before a hardware or software write that can change the display.
    public func beginWrite() -> Bool {
        guard isTargetCurrent else { return false }
        return state.withLock {
            guard !$0.cancelled else { return false }
            $0.didAttemptWrite = true
            return true
        }
    }

    public func cancel() {
        state.withLock { $0.cancelled = true }
    }
}
