import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c
import MacToolsPluginKit

private enum DDCBrightnessControl {
    static let brightness: UInt8 = 0x10
    static let hostAddress: UInt8 = 0x51
    static let displayAddress: UInt8 = 0x6E
    static let displayReplyAddress: UInt8 = 0x6F
    static let arm64DisplayAddress7Bit: UInt8 = 0x37
    static let writeCycleCount = 2
    static let retryCount = 3
    static let writeDelay: useconds_t = 40_000
    static let readDelay: useconds_t = 50_000
    static let retryDelay: useconds_t = 20_000
}

struct DDCBrightnessValue {
    let current: UInt16
    let maximum: UInt16
}

protocol DDCBrightnessTransport {
    func readBrightness() throws -> DDCBrightnessValue
    func writeBrightness(_ value: UInt16) throws
}

private enum DDCCommunicationQueue {
    static let shared = DispatchQueue(label: "MacTools.DisplayBrightness.DDC")
}

final class IntelDDCTransport: DDCBrightnessTransport, @unchecked Sendable {
    private let display: DisplayInfo
    private let framebuffer: io_service_t
    private let replyTransactionType: IOOptionBits

    init?(display: DisplayInfo) {
        guard let framebuffer = Self.framebufferPort(for: display.id) else {
            DisplayBrightnessLog.backend.info(
                "DDC Intel transport unavailable for \(display.name, privacy: .public): no framebuffer service"
            )
            return nil
        }

        guard let replyTransactionType = Self.supportedReplyTransactionType() else {
            IOObjectRelease(framebuffer)
            DisplayBrightnessLog.backend.info(
                "DDC Intel transport unavailable for \(display.name, privacy: .public): no supported I2C reply transaction type"
            )
            return nil
        }

        self.display = display
        self.framebuffer = framebuffer
        self.replyTransactionType = replyTransactionType
        DisplayBrightnessLog.backend.debug(
            "DDC Intel transport ready for \(display.name, privacy: .public)"
        )
    }

    deinit {
        IOObjectRelease(framebuffer)
    }

    func readBrightness() throws -> DDCBrightnessValue {
        try DDCCommunicationQueue.shared.sync {
            var lastError: Error?

            for _ in 0..<DDCBrightnessControl.retryCount {
                do {
                    return try performRead()
                } catch {
                    lastError = error
                    usleep(DDCBrightnessControl.retryDelay)
                }
            }

            throw lastError ?? DisplayBrightnessControllerError.i2cUnavailable(displayName: display.name)
        }
    }

    func writeBrightness(_ value: UInt16) throws {
        try DDCCommunicationQueue.shared.sync {
            var didWrite = false

            for _ in 0..<DDCBrightnessControl.writeCycleCount {
                usleep(DDCBrightnessControl.writeDelay)
                didWrite = performWrite(value) || didWrite
            }

            guard didWrite else {
                throw DisplayBrightnessControllerError.ddcWriteFailed(displayName: display.name)
            }
        }
    }

    private func performRead() throws -> DDCBrightnessValue {
        var command = [
            DDCBrightnessControl.hostAddress,
            0x82,
            0x01,
            DDCBrightnessControl.brightness
        ]
        command.append(Self.checksum(seed: DDCBrightnessControl.displayAddress, bytes: command))
        var reply = Array(repeating: UInt8.zero, count: 11)

        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = UInt32(DDCBrightnessControl.displayAddress)
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendBytes = UInt32(command.count)
        request.sendBuffer = command.withUnsafeBufferPointer {
            vm_address_t(bitPattern: $0.baseAddress)
        }
        request.minReplyDelay = 10
        request.replyAddress = UInt32(DDCBrightnessControl.displayReplyAddress)
        request.replySubAddress = DDCBrightnessControl.hostAddress
        request.replyTransactionType = replyTransactionType
        request.replyBytes = UInt32(reply.count)
        request.replyBuffer = reply.withUnsafeMutableBufferPointer {
            vm_address_t(bitPattern: $0.baseAddress)
        }

        guard Self.send(request: &request, to: framebuffer) else {
            throw DisplayBrightnessControllerError.i2cUnavailable(displayName: display.name)
        }

        return try Self.parseReply(reply, displayName: display.name)
    }

    private func performWrite(_ value: UInt16) -> Bool {
        var command = [
            DDCBrightnessControl.hostAddress,
            0x84,
            0x03,
            DDCBrightnessControl.brightness,
            UInt8(value >> 8),
            UInt8(value & 0xFF)
        ]
        command.append(Self.checksum(seed: DDCBrightnessControl.displayAddress, bytes: command))

        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = UInt32(DDCBrightnessControl.displayAddress)
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendBytes = UInt32(command.count)
        request.sendBuffer = command.withUnsafeBufferPointer {
            vm_address_t(bitPattern: $0.baseAddress)
        }
        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
        request.replyBytes = 0

        return Self.send(request: &request, to: framebuffer)
    }

    static func parseReply(
        _ reply: [UInt8],
        displayName: String
    ) throws -> DDCBrightnessValue {
        guard reply.count >= 10 else {
            throw DisplayBrightnessControllerError.unsupportedReply(displayName: displayName)
        }

        let checksum = checksum(seed: 0x50, bytes: Array(reply.dropLast()))
        guard checksum == reply.last else {
            throw DisplayBrightnessControllerError.unsupportedReply(displayName: displayName)
        }

        guard reply[2] == 0x02, reply[3] == 0x00 else {
            throw DisplayBrightnessControllerError.unsupportedReply(displayName: displayName)
        }

        return DDCBrightnessValue(
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])
        )
    }

    private static func checksum(seed: UInt8, bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    private static func send(request: inout IOI2CRequest, to framebuffer: io_service_t) -> Bool {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else {
            return false
        }

        for bus in 0..<busCount {
            var interface = io_service_t()
            guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS else {
                continue
            }

            defer {
                IOObjectRelease(interface)
            }

            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else {
                continue
            }

            defer {
                IOI2CInterfaceClose(connect, 0)
            }

            if IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS, request.result == KERN_SUCCESS {
                return true
            }
        }

        return false
    }

    private static func supportedReplyTransactionType() -> IOOptionBits? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceNameMatching("IOFramebufferI2CInterface"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }

        defer {
            IOObjectRelease(iterator)
        }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer {
                IOObjectRelease(service)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any],
            let types = dictionary[kIOI2CTransactionTypesKey] as? UInt64
            else {
                continue
            }

            if (1 << kIOI2CDDCciReplyTransactionType) & types != 0 {
                return IOOptionBits(kIOI2CDDCciReplyTransactionType)
            }

            if (1 << kIOI2CSimpleTransactionType) & types != 0 {
                return IOOptionBits(kIOI2CSimpleTransactionType)
            }
        }

        return nil
    }

    private static func framebufferPort(for displayID: CGDirectDisplayID) -> io_service_t? {
        if let cgsService = PrivateDDCBridge.framebufferService(for: displayID) {
            return cgsService
        }

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }

        defer {
            IOObjectRelease(iterator)
        }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let vendorID = CGDisplayVendorNumber(displayID)
            let modelID = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)

            let infoDictionary = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary

            let matchesVendor = (infoDictionary[kDisplayVendorID] as? UInt32) == vendorID
            let matchesModel = (infoDictionary[kDisplayProductID] as? UInt32) == modelID
            let displaySerial = infoDictionary[kDisplaySerialNumber] as? UInt32
            let matchesSerial = serialNumber == 0 || displaySerial == serialNumber

            if matchesVendor && matchesModel && matchesSerial {
                return service
            }

            IOObjectRelease(service)
        }

        return nil
    }
}

final class Arm64DDCTransport: DDCBrightnessTransport, @unchecked Sendable {
    private let display: DisplayInfo
    private let service: CFTypeRef

    init?(display: DisplayInfo, service matchedService: CFTypeRef?) {
        guard
            let service = matchedService ?? PrivateDDCBridge.createService(for: display.id)
        else {
            DisplayBrightnessLog.backend.info(
                "DDC ARM64 transport unavailable for \(display.name, privacy: .public): no IOAV service"
            )
            return nil
        }

        self.display = display
        self.service = service
        DisplayBrightnessLog.backend.debug(
            "DDC ARM64 transport ready for \(display.name, privacy: .public)"
        )
    }

    func readBrightness() throws -> DDCBrightnessValue {
        try DDCCommunicationQueue.shared.sync {
            var payload = [DDCBrightnessControl.brightness]
            var reply = Array(repeating: UInt8.zero, count: 11)
            try performCommunication(send: &payload, reply: &reply)
            return try IntelDDCTransport.parseReply(reply, displayName: display.name)
        }
    }

    func writeBrightness(_ value: UInt16) throws {
        try DDCCommunicationQueue.shared.sync {
            var payload = [
                DDCBrightnessControl.brightness,
                UInt8(value >> 8),
                UInt8(value & 0xFF)
            ]
            var reply: [UInt8] = []
            try performCommunication(send: &payload, reply: &reply)
        }
    }

    private func performCommunication(send: inout [UInt8], reply: inout [UInt8]) throws {
        var packet = [UInt8(0x80 | UInt8(send.count + 1)), UInt8(send.count)] + send + [0]
        let seed = send.count == 1
            ? DDCBrightnessControl.arm64DisplayAddress7Bit << 1
            : (DDCBrightnessControl.arm64DisplayAddress7Bit << 1) ^ DDCBrightnessControl.hostAddress
        packet[packet.count - 1] = packet.dropLast().reduce(seed, ^)

        var didWrite = false
        for _ in 0..<DDCBrightnessControl.writeCycleCount {
            usleep(DDCBrightnessControl.writeDelay)
            if PrivateDDCBridge.writeI2C(
                service: service,
                address: UInt32(DDCBrightnessControl.arm64DisplayAddress7Bit),
                dataAddress: UInt32(DDCBrightnessControl.hostAddress),
                bytes: &packet
            ) == KERN_SUCCESS {
                didWrite = true
            }
        }

        guard didWrite else {
            throw DisplayBrightnessControllerError.ddcWriteFailed(displayName: display.name)
        }

        guard !reply.isEmpty else {
            return
        }

        for _ in 0..<DDCBrightnessControl.retryCount {
            usleep(DDCBrightnessControl.readDelay)
            if PrivateDDCBridge.readI2C(
                service: service,
                address: UInt32(DDCBrightnessControl.arm64DisplayAddress7Bit),
                dataAddress: 0,
                bytes: &reply
            ) == KERN_SUCCESS {
                return
            }

            usleep(DDCBrightnessControl.retryDelay)
        }

        throw DisplayBrightnessControllerError.i2cUnavailable(displayName: display.name)
    }
}

enum Arm64DDCServiceMatcher {
    struct CandidateService {
        let service: CFTypeRef
        let name: String?
        let vendorNumber: UInt32?
        let serialNumber: UInt32?
        let productID: UInt32?
        let manufactureYear: UInt32?
        let manufactureWeek: UInt32?
        let location: String?
        let ioDisplayLocation: String?
        let edidUUID: String?
        let serviceLocation: Int

        init(
            service: CFTypeRef,
            name: String? = nil,
            vendorNumber: UInt32? = nil,
            serialNumber: UInt32? = nil,
            productID: UInt32? = nil,
            manufactureYear: UInt32? = nil,
            manufactureWeek: UInt32? = nil,
            location: String? = nil,
            ioDisplayLocation: String? = nil,
            edidUUID: String? = nil,
            serviceLocation: Int = 0
        ) {
            self.service = service
            self.name = name
            self.vendorNumber = vendorNumber
            self.serialNumber = serialNumber
            self.productID = productID
            self.manufactureYear = manufactureYear
            self.manufactureWeek = manufactureWeek
            self.location = location
            self.ioDisplayLocation = ioDisplayLocation
            self.edidUUID = edidUUID
            self.serviceLocation = serviceLocation
        }
    }

    static func resolveServices(for displays: [DisplayInfo]) -> [CGDirectDisplayID: CFTypeRef] {
        resolveServices(for: displays, candidates: discoverCandidates())
    }

    static func resolveServices(
        for displays: [DisplayInfo],
        candidates: [CandidateService]
    ) -> [CGDirectDisplayID: CFTypeRef] {
        let scoredMatches = scoredCandidateMatches(
            for: displays.filter { !$0.isBuiltin },
            candidates: candidates
        )
        var matches: [CGDirectDisplayID: CFTypeRef] = [:]
        var usedDisplayIDs: Set<CGDirectDisplayID> = []
        var usedCandidateIndexes: Set<Int> = []

        for match in scoredMatches {
            guard
                !usedDisplayIDs.contains(match.display.id),
                !usedCandidateIndexes.contains(match.candidateIndex)
            else {
                continue
            }

            matches[match.display.id] = match.candidate.service
            usedDisplayIDs.insert(match.display.id)
            usedCandidateIndexes.insert(match.candidateIndex)
        }

        assignRemainingServicesByStableOrder(
            displays: displays.filter { !$0.isBuiltin },
            candidates: candidates,
            matches: &matches,
            usedCandidateIndexes: usedCandidateIndexes
        )

        return matches
    }

    private static func assignRemainingServicesByStableOrder(
        displays: [DisplayInfo],
        candidates: [CandidateService],
        matches: inout [CGDirectDisplayID: CFTypeRef],
        usedCandidateIndexes: Set<Int>
    ) {
        let unmatchedDisplays = displays
            .filter { matches[$0.id] == nil }
            .sorted(by: stableDisplaySort)
        let unusedCandidates = candidates.indices
            .filter { !usedCandidateIndexes.contains($0) && isExternalCandidate(candidates[$0]) }
            .map { candidates[$0] }
            .sorted(by: stableCandidateSort)

        guard
            !unmatchedDisplays.isEmpty,
            unmatchedDisplays.count == unusedCandidates.count
        else {
            return
        }

        for (display, candidate) in zip(unmatchedDisplays, unusedCandidates) {
            matches[display.id] = candidate.service
        }
    }

    private static func discoverCandidates() -> [CandidateService] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceNameMatching("DCPAVServiceProxy"),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }

        defer {
            IOObjectRelease(iterator)
        }

        var result: [CandidateService] = []
        var serviceLocation = 0

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer {
                IOObjectRelease(service)
            }

            guard let avService = PrivateDDCBridge.createService(with: service) else {
                continue
            }

            let location = searchedProperty(
                key: "Location",
                service: service
            ) as? String
            guard location?.localizedCaseInsensitiveContains("external") ?? true else {
                continue
            }

            let nearbyDisplayProperties = nearbyDisplayProperties(for: service) ?? [:]
            let serviceDisplayAttributes = searchedProperty(
                key: "DisplayAttributes",
                service: service
            ) as? [String: Any]
            let displayAttributes = serviceDisplayAttributes ?? nearbyDisplayProperties["DisplayAttributes"] as? [String: Any]
            let productAttributes = displayAttributes?["ProductAttributes"] as? [String: Any]

            serviceLocation += 1
            result.append(
                CandidateService(
                    service: avService,
                    name: productAttributes?["ProductName"] as? String,
                    vendorNumber: numericValue(productAttributes?["LegacyManufacturerID"])
                        ?? numericValue(productAttributes?["ManufacturerID"]),
                    serialNumber: numericValue(productAttributes?["SerialNumber"]),
                    productID: numericValue(productAttributes?["ProductID"]),
                    manufactureYear: numericValue(productAttributes?["YearOfManufacture"]),
                    manufactureWeek: numericValue(productAttributes?["WeekOfManufacture"]),
                    location: location,
                    ioDisplayLocation: (searchedProperty(
                        key: kIODisplayLocationKey,
                        service: service
                    ) as? String) ?? servicePathKey(for: service),
                    edidUUID: (searchedProperty(
                        key: "EDID UUID",
                        service: service
                    ) as? String) ?? nearbyDisplayProperties["EDID UUID"] as? String
                        ?? nearbyDisplayProperties["IOMFBUUID"] as? String,
                    serviceLocation: serviceLocation
                )
            )
        }

        return result
    }

    private struct ScoredCandidateMatch {
        let display: DisplayInfo
        let candidateIndex: Int
        let candidate: CandidateService
        let score: Int
    }

    private static func scoredCandidateMatches(
        for displays: [DisplayInfo],
        candidates: [CandidateService]
    ) -> [ScoredCandidateMatch] {
        var scoredMatches: [ScoredCandidateMatch] = []

        for display in displays {
            for index in candidates.indices {
                let candidate = candidates[index]
                let score = matchScore(display: display, candidate: candidate)
                guard score >= 4 else {
                    continue
                }

                scoredMatches.append(
                    ScoredCandidateMatch(
                        display: display,
                        candidateIndex: index,
                        candidate: candidate,
                        score: score
                    )
                )
            }
        }

        return scoredMatches.sorted {
            if $0.score == $1.score {
                if $0.display.id == $1.display.id {
                    return $0.candidate.serviceLocation < $1.candidate.serviceLocation
                }

                return $0.display.id < $1.display.id
            }

            return $0.score > $1.score
        }
    }

    private static func stableDisplaySort(_ lhs: DisplayInfo, _ rhs: DisplayInfo) -> Bool {
        let lhsLocation = displayLocation(for: lhs.id) ?? ""
        let rhsLocation = displayLocation(for: rhs.id) ?? ""

        if lhsLocation != rhsLocation {
            return lhsLocation < rhsLocation
        }

        return lhs.id < rhs.id
    }

    private static func isExternalCandidate(_ candidate: CandidateService) -> Bool {
        guard let location = candidate.location?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        return location.localizedCaseInsensitiveCompare("External") == .orderedSame
    }

    private static func stableCandidateSort(_ lhs: CandidateService, _ rhs: CandidateService) -> Bool {
        let lhsLocation = lhs.ioDisplayLocation ?? ""
        let rhsLocation = rhs.ioDisplayLocation ?? ""

        if lhsLocation != rhsLocation {
            return lhsLocation < rhsLocation
        }

        return lhs.serviceLocation < rhs.serviceLocation
    }

    private static func matchScore(display: DisplayInfo, candidate: CandidateService) -> Int {
        var score = 0

        if let displayLocation = displayLocation(for: display.id),
           let candidateLocation = candidate.ioDisplayLocation,
           !displayLocation.isEmpty,
           displayLocation == candidateLocation {
            score += 12
        }

        score += edidMatchScore(displayID: display.id, edidUUID: candidate.edidUUID)

        if let serialNumber = display.serialNumber, serialNumber != 0, serialNumber == candidate.serialNumber {
            score += 10
        }

        if let vendorNumber = display.vendorNumber,
           let candidateVendorNumber = candidate.vendorNumber,
           vendorNumber == candidateVendorNumber {
            score += 3
        }

        if let modelNumber = display.modelNumber,
           let productID = candidate.productID,
           modelNumber == productID {
            score += 6
        }

        score += displayAttributesMatchScore(displayID: display.id, candidate: candidate)

        if let name = candidate.name,
           normalizedDisplayName(name) == normalizedDisplayName(display.name) {
            score += 2
        }

        if let location = candidate.location, location.localizedCaseInsensitiveContains("external") {
            score += 1
        }

        return score
    }

    private static func edidMatchScore(displayID: CGDirectDisplayID, edidUUID: String?) -> Int {
        guard
            let edidUUID,
            !edidUUID.isEmpty,
            let dictionary = displayInfoDictionary(for: displayID)
        else {
            return 0
        }

        var score = 0
        let uppercaseUUID = edidUUID.uppercased()

        if let vendorID = dictionary[kDisplayVendorID] as? Int64,
           uuidToken(UInt16(clamping: vendorID), byteSwapped: false).map({ uppercaseUUID.hasPrefix($0) }) == true {
            score += 2
        }

        if let productID = dictionary[kDisplayProductID] as? Int64,
           let token = uuidToken(UInt16(clamping: productID), byteSwapped: true),
           uppercaseUUID.contains(token) {
            score += 2
        }

        if let week = dictionary[kDisplayWeekOfManufacture] as? Int64,
           let year = dictionary[kDisplayYearOfManufacture] as? Int64,
           let token = manufactureDateToken(week: week, year: year),
           uppercaseUUID.contains(token) {
            score += 2
        }

        if let horizontalSize = dictionary[kDisplayHorizontalImageSize] as? Int64,
           let verticalSize = dictionary[kDisplayVerticalImageSize] as? Int64,
           let token = imageSizeToken(horizontal: horizontalSize, vertical: verticalSize),
           uppercaseUUID.contains(token) {
            score += 2
        }

        return score
    }

    private static func displayAttributesMatchScore(
        displayID: CGDirectDisplayID,
        candidate: CandidateService
    ) -> Int {
        guard let dictionary = displayInfoDictionary(for: displayID) else {
            return 0
        }

        var score = 0

        if let serialNumber = dictionary[kDisplaySerialNumber] as? Int64,
           serialNumber > 0,
           UInt32(clamping: serialNumber) == candidate.serialNumber {
            score += 10
        }

        if let vendorID = dictionary[kDisplayVendorID] as? Int64,
           vendorID > 0,
           UInt32(clamping: vendorID) == candidate.vendorNumber {
            score += 3
        }

        if let productID = dictionary[kDisplayProductID] as? Int64,
           productID > 0,
           UInt32(clamping: productID) == candidate.productID {
            score += 6
        }

        if let year = dictionary[kDisplayYearOfManufacture] as? Int64,
           year > 0,
           UInt32(clamping: year) == candidate.manufactureYear {
            score += 2
        }

        if let week = dictionary[kDisplayWeekOfManufacture] as? Int64,
           week > 0,
           UInt32(clamping: week) == candidate.manufactureWeek {
            score += 2
        }

        return score
    }

    private static func uuidToken(_ value: UInt16, byteSwapped: Bool) -> String? {
        if value == 0 {
            return nil
        }

        let normalizedValue = byteSwapped ? value.byteSwapped : value
        return String(format: "%04X", normalizedValue)
    }

    private static func manufactureDateToken(week: Int64, year: Int64) -> String? {
        let normalizedWeek = UInt8(clamping: week)
        let normalizedYear = UInt8(clamping: year - 1990)
        guard normalizedWeek != 0 || normalizedYear != 0 else {
            return nil
        }

        return String(format: "%02X%02X", normalizedWeek, normalizedYear)
    }

    private static func imageSizeToken(horizontal: Int64, vertical: Int64) -> String? {
        let normalizedHorizontal = UInt8(clamping: horizontal / 10)
        let normalizedVertical = UInt8(clamping: vertical / 10)
        guard normalizedHorizontal != 0 || normalizedVertical != 0 else {
            return nil
        }

        return String(format: "%02X%02X", normalizedHorizontal, normalizedVertical)
    }

    private static func normalizedDisplayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func numericValue(_ value: Any?) -> UInt32? {
        switch value {
        case let value as UInt32:
            return value == 0 ? nil : value
        case let value as UInt64:
            guard value <= UInt64(UInt32.max) else {
                return nil
            }

            return value == 0 ? nil : UInt32(value)
        case let value as Int:
            guard value > 0, value <= Int(UInt32.max) else {
                return nil
            }

            return UInt32(value)
        case let value as String:
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return UInt32(normalizedValue) ?? eisaManufacturerID(normalizedValue)
        default:
            return nil
        }
    }

    private static func eisaManufacturerID(_ value: String) -> UInt32? {
        let characters = Array(value.uppercased())
        guard characters.count == 3 else {
            return nil
        }

        var encodedValue: UInt32 = 0
        for character in characters {
            guard
                let scalar = character.unicodeScalars.first,
                scalar.value >= 65,
                scalar.value <= 90
            else {
                return nil
            }

            encodedValue = (encodedValue << 5) | UInt32(scalar.value - 64)
        }

        return encodedValue == 0 ? nil : encodedValue
    }

    static func displayInfoDictionary(for displayID: CGDirectDisplayID) -> NSDictionary? {
        guard let createInfoDictionary = PrivateDDCBridge.coreDisplayCreateInfoDictionary else {
            return nil
        }

        return createInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?
    }

    private static func displayLocation(for displayID: CGDirectDisplayID) -> String? {
        if let location = displayInfoDictionary(for: displayID)?[kIODisplayLocationKey] as? String {
            return location
        }

        guard let service = PrivateDDCBridge.framebufferService(for: displayID) else {
            return nil
        }

        return servicePathKey(for: service)
    }

    private static func nearbyDisplayProperties(for service: io_service_t) -> [String: Any]? {
        guard let pathKey = servicePathKey(for: service) else {
            return nil
        }

        let displayServiceNames = [
            "AppleCLCD2",
            "IOMobileFramebufferShim"
        ]

        for serviceName in displayServiceNames {
            if let properties = nearbyDisplayProperties(
                serviceName: serviceName,
                pathKey: pathKey
            ) {
                return properties
            }
        }

        return nil
    }

    private static func nearbyDisplayProperties(
        serviceName: String,
        pathKey: String
    ) -> [String: Any]? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceNameMatching(serviceName),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }

        defer {
            IOObjectRelease(iterator)
        }

        while case let displayService = IOIteratorNext(iterator), displayService != 0 {
            defer {
                IOObjectRelease(displayService)
            }

            guard servicePathKey(for: displayService) == pathKey else {
                continue
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                displayService,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS else {
                continue
            }

            return properties?.takeRetainedValue() as? [String: Any]
        }

        return nil
    }

    private static func servicePathKey(for service: io_service_t) -> String? {
        guard
            let unmanagedPath = IORegistryEntryCopyPath(service, kIOServicePlane),
            let path = unmanagedPath.takeRetainedValue() as String?
        else {
            return nil
        }

        let pattern = #"(?:^|/)disp(?:ext)?\d+(?=[@:/])"#
        guard let range = path.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        return String(path[range]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func searchedProperty(key: String, service: io_service_t) -> AnyObject? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }
}

private extension UInt16 {
    init(clamping value: Int64) {
        if value < 0 {
            self = 0
        } else if value > Int64(UInt16.max) {
            self = UInt16.max
        } else {
            self = UInt16(value)
        }
    }
}

private extension UInt8 {
    init(clamping value: Int64) {
        if value < 0 {
            self = 0
        } else if value > Int64(UInt8.max) {
            self = UInt8.max
        } else {
            self = UInt8(value)
        }
    }
}

private extension UInt32 {
    init(clamping value: Int) {
        if value < 0 {
            self = 0
        } else if value > Int(UInt32.max) {
            self = UInt32.max
        } else {
            self = UInt32(value)
        }
    }
}

private enum PrivateDDCBridge {
    typealias CoreDisplayCreateInfoDictionaryFunction = @convention(c) (
        CGDirectDisplayID
    ) -> Unmanaged<CFDictionary>?

    private typealias CreateWithServiceFunction = @convention(c) (
        CFAllocator?,
        io_service_t
    ) -> Unmanaged<CFTypeRef>?
    private typealias ReadI2CFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer?,
        UInt32
    ) -> kern_return_t
    private typealias WriteI2CFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer?,
        UInt32
    ) -> kern_return_t
    private typealias CGSServiceFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<io_service_t>
    ) -> Void

    private static let privateFrameworkPaths = [
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    ]

    private static let createWithService: CreateWithServiceFunction? = loadSymbol("IOAVServiceCreateWithService")
    private static let read: ReadI2CFunction? = loadSymbol("IOAVServiceReadI2C")
    private static let write: WriteI2CFunction? = loadSymbol("IOAVServiceWriteI2C")
    private static let cgsServiceForDisplay: CGSServiceFunction? = loadSymbol("CGSServiceForDisplayNumber")
    static let coreDisplayCreateInfoDictionary: CoreDisplayCreateInfoDictionaryFunction? = loadSymbol(
        "CoreDisplay_DisplayCreateInfoDictionary"
    )

    static func createService(for displayID: CGDirectDisplayID) -> CFTypeRef? {
        guard let service = framebufferService(for: displayID), let createWithService else {
            if createWithService == nil {
                DisplayBrightnessLog.backend.info("DDC private symbol IOAVServiceCreateWithService is unavailable")
            }
            return nil
        }

        return createWithService(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    static func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        guard let cgsServiceForDisplay else {
            DisplayBrightnessLog.backend.info("DDC private symbol CGSServiceForDisplayNumber is unavailable")
            return nil
        }

        var service = io_service_t()
        cgsServiceForDisplay(displayID, &service)
        guard service != 0 else {
            return nil
        }

        return service
    }

    static func createService(with service: io_service_t) -> CFTypeRef? {
        createWithService?(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    static func readI2C(
        service: CFTypeRef,
        address: UInt32,
        dataAddress: UInt32,
        bytes: inout [UInt8]
    ) -> kern_return_t {
        guard let read else {
            return kIOReturnUnsupported
        }

        return bytes.withUnsafeMutableBytes { buffer in
            read(service, address, dataAddress, buffer.baseAddress, UInt32(buffer.count))
        }
    }

    static func writeI2C(
        service: CFTypeRef,
        address: UInt32,
        dataAddress: UInt32,
        bytes: inout [UInt8]
    ) -> kern_return_t {
        guard let write else {
            return kIOReturnUnsupported
        }

        return bytes.withUnsafeMutableBytes { buffer in
            write(service, address, dataAddress, buffer.baseAddress, UInt32(buffer.count))
        }
    }

    private static func loadSymbol<T>(_ symbol: String) -> T? {
        for path in privateFrameworkPaths {
            guard
                let handle = dlopen(path, RTLD_LAZY),
                let pointer = dlsym(handle, symbol)
            else {
                continue
            }

            return unsafeBitCast(pointer, to: T.self)
        }

        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) else {
            return nil
        }

        return unsafeBitCast(pointer, to: T.self)
    }
}
