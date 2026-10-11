import Foundation
import MacToolsPluginKit

enum DeviceBatteryLayoutMode: String, CaseIterable, Equatable {
    case grid
    case list

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .grid:
            return localization.string("layout.grid.title", defaultValue: "列表")
        case .list:
            return localization.string("layout.list.title", defaultValue: "圆环")
        }
    }

    func subtitle(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .grid:
            return localization.string("layout.grid.subtitle", defaultValue: "按设备逐行显示")
        case .list:
            return localization.string("layout.list.subtitle", defaultValue: "多设备圆环")
        }
    }

}

enum DeviceBatteryChargeState: Equatable, Sendable {
    case unknown
    case normal
    case charging
    case charged
    case plugged
    case invalid

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .unknown:
            return localization.string("chargeState.unknown", defaultValue: "未知")
        case .normal:
            return localization.string("chargeState.normal", defaultValue: "正常")
        case .charging:
            return localization.string("chargeState.charging", defaultValue: "充电中")
        case .charged:
            return localization.string("chargeState.charged", defaultValue: "已充满")
        case .plugged:
            return localization.string("chargeState.plugged", defaultValue: "外接电源")
        case .invalid:
            return localization.string("chargeState.invalid", defaultValue: "电量无效")
        }
    }

    var isActiveChargingState: Bool {
        switch self {
        case .charging, .charged, .plugged:
            return true
        case .unknown, .normal, .invalid:
            return false
        }
    }
}

enum DeviceBatteryKind: Equatable, Sendable {
    case internalBattery
    case phone
    case tablet
    case mediaPlayer
    case watch
    case spatialComputer
    case bluetooth
    case magicAccessory
    case vendorHIDMouse
    case airPodsPart
    case other

    var iconName: String {
        switch self {
        case .internalBattery:
            return "laptopcomputer"
        case .phone:
            return "iphone"
        case .tablet:
            return "ipad"
        case .mediaPlayer:
            return "ipodtouch"
        case .watch:
            return "applewatch"
        case .spatialComputer:
            return "visionpro"
        case .bluetooth:
            return "dot.radiowaves.left.and.right"
        case .magicAccessory:
            return "keyboard"
        case .vendorHIDMouse:
            return "computermouse.fill"
        case .airPodsPart:
            return "airpodspro"
        case .other:
            return "battery.75percent"
        }
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .internalBattery:
            return "Mac"
        case .phone:
            return "iPhone"
        case .tablet:
            return "iPad"
        case .mediaPlayer:
            return "iPod touch"
        case .watch:
            return "Apple Watch"
        case .spatialComputer:
            return "Apple Vision Pro"
        case .bluetooth:
            return localization.string("deviceKind.bluetooth", defaultValue: "蓝牙")
        case .magicAccessory:
            return localization.string("deviceKind.magicAccessory", defaultValue: "Apple 外设")
        case .vendorHIDMouse:
            return localization.string("deviceKind.vendorHIDMouse", defaultValue: "厂商鼠标")
        case .airPodsPart:
            return localization.string("deviceKind.airPodsPart", defaultValue: "耳机")
        case .other:
            return localization.string("deviceKind.other", defaultValue: "设备")
        }
    }
}

enum DeviceBatteryComponentRole: String, Equatable, Hashable, Sendable {
    case aggregate
    case earbuds
    case left
    case right
    case chargingCase

    var isPart: Bool {
        self != .aggregate
    }
}

enum DeviceBatteryLowBatteryThresholds {
    static let defaultValue = 20
    static let minimum = 1
    static let maximum = 99

    static func normalized(_ threshold: Int) -> Int {
        min(max(threshold, minimum), maximum)
    }
}

struct DeviceBatteryComponentIdentity: Equatable, Sendable {
    let groupID: String
    let role: DeviceBatteryComponentRole
}

struct DeviceBatteryDeviceIdentity: Equatable, Hashable, Sendable {
    enum Namespace: String, Sendable {
        case internalBattery
        case bluetooth
        case batteryCenter
        case mobileDevice
        case vendorHID
        case source
    }

    let namespace: Namespace
    let value: String

    var key: String {
        "\(namespace.rawValue):\(value)"
    }

    static let internalBattery = DeviceBatteryDeviceIdentity(
        namespace: .internalBattery,
        value: "main"
    )

    static func bluetooth(_ identifier: String) -> DeviceBatteryDeviceIdentity {
        DeviceBatteryDeviceIdentity(namespace: .bluetooth, value: identifier)
    }

    static func batteryCenter(_ identifier: String) -> DeviceBatteryDeviceIdentity {
        DeviceBatteryDeviceIdentity(namespace: .batteryCenter, value: identifier)
    }

    static func mobileDevice(_ identifier: String) -> DeviceBatteryDeviceIdentity {
        DeviceBatteryDeviceIdentity(namespace: .mobileDevice, value: identifier)
    }

    static func vendorHID(_ identifier: String) -> DeviceBatteryDeviceIdentity {
        DeviceBatteryDeviceIdentity(namespace: .vendorHID, value: identifier)
    }

    static func vendorHID(_ vendor: VendorHIDVendor, _ identifier: String) -> DeviceBatteryDeviceIdentity {
        DeviceBatteryDeviceIdentity(namespace: .vendorHID, value: "\(vendor)-\(identifier)")
    }

    static func source(_ identifier: String) -> DeviceBatteryDeviceIdentity {
        DeviceBatteryDeviceIdentity(namespace: .source, value: identifier)
    }
}

struct DeviceBatteryItem: Identifiable, Equatable, Sendable {
    let id: String
    let deviceIdentity: DeviceBatteryDeviceIdentity
    let name: String
    let model: String?
    let kind: DeviceBatteryKind
    let level: Int?
    let chargeState: DeviceBatteryChargeState
    let parentName: String?
    let source: String
    let lastUpdated: Date?
    let chargeStateLastUpdated: Date?
    let isConnected: Bool
    let detail: String?
    let componentIdentity: DeviceBatteryComponentIdentity?
    let alternateDeviceIdentities: Set<DeviceBatteryDeviceIdentity>

    init(
        id: String,
        deviceIdentity: DeviceBatteryDeviceIdentity,
        name: String,
        model: String?,
        kind: DeviceBatteryKind,
        level: Int?,
        chargeState: DeviceBatteryChargeState,
        parentName: String?,
        source: String,
        lastUpdated: Date?,
        chargeStateLastUpdated: Date? = nil,
        isConnected: Bool,
        detail: String?,
        componentIdentity: DeviceBatteryComponentIdentity? = nil,
        alternateDeviceIdentities: Set<DeviceBatteryDeviceIdentity> = []
    ) {
        self.id = id
        self.deviceIdentity = deviceIdentity
        self.name = name
        self.model = model
        self.kind = kind
        self.level = level
        self.chargeState = chargeState
        self.parentName = parentName
        self.source = source
        self.lastUpdated = lastUpdated
        if chargeState == .unknown || chargeState == .invalid {
            self.chargeStateLastUpdated = nil
        } else {
            self.chargeStateLastUpdated = chargeStateLastUpdated ?? lastUpdated
        }
        self.isConnected = isConnected
        self.detail = detail
        self.componentIdentity = componentIdentity
        self.alternateDeviceIdentities = alternateDeviceIdentities
    }

    var batterySlot: DeviceBatteryComponentRole {
        componentIdentity?.role ?? .aggregate
    }

    var stableBatteryIdentityKey: String {
        "\(deviceIdentity.key)|\(batterySlot.rawValue)"
    }

    var allDeviceIdentities: Set<DeviceBatteryDeviceIdentity> {
        Set([deviceIdentity]).union(alternateDeviceIdentities)
    }

    var allEquivalentBatteryIdentityKeys: Set<String> {
        let slots: [DeviceBatteryComponentRole]
        if kind == .airPodsPart,
           batterySlot == .aggregate || batterySlot == .earbuds {
            slots = [.aggregate, .earbuds]
        } else {
            slots = [batterySlot]
        }

        return Set(
            ([deviceIdentity] + alternateDeviceIdentities).flatMap { identity in
                slots.map { "\(identity.key)|\($0.rawValue)" }
            }
        )
    }

    func resolvingDeviceIdentity(
        to resolvedIdentity: DeviceBatteryDeviceIdentity
    ) -> DeviceBatteryItem {
        guard resolvedIdentity != deviceIdentity else {
            return self
        }

        var alternateIdentities = alternateDeviceIdentities
        alternateIdentities.insert(deviceIdentity)
        alternateIdentities.remove(resolvedIdentity)
        return copying(
            deviceIdentity: resolvedIdentity,
            alternateDeviceIdentities: alternateIdentities
        )
    }

    func mergingDeviceIdentityAliases(from other: DeviceBatteryItem) -> DeviceBatteryItem {
        var alternateIdentities = alternateDeviceIdentities
            .union(other.alternateDeviceIdentities)
        if other.deviceIdentity != deviceIdentity {
            alternateIdentities.insert(other.deviceIdentity)
        }
        alternateIdentities.remove(deviceIdentity)
        return copying(alternateDeviceIdentities: alternateIdentities)
    }

    func removingDeviceIdentityAliases(
        _ identities: Set<DeviceBatteryDeviceIdentity>
    ) -> DeviceBatteryItem {
        copying(
            alternateDeviceIdentities: alternateDeviceIdentities
                .subtracting(identities)
        )
    }

    private func copying(
        deviceIdentity: DeviceBatteryDeviceIdentity? = nil,
        alternateDeviceIdentities: Set<DeviceBatteryDeviceIdentity>
    ) -> DeviceBatteryItem {
        let resolvedDeviceIdentity = deviceIdentity ?? self.deviceIdentity
        let resolvedComponentIdentity = componentIdentity.map { identity in
            guard identity.groupID == self.deviceIdentity.key else {
                return identity
            }
            return DeviceBatteryComponentIdentity(
                groupID: resolvedDeviceIdentity.key,
                role: identity.role
            )
        }
        return DeviceBatteryItem(
            id: id,
            deviceIdentity: resolvedDeviceIdentity,
            name: name,
            model: model,
            kind: kind,
            level: level,
            chargeState: chargeState,
            parentName: parentName,
            source: source,
            lastUpdated: lastUpdated,
            chargeStateLastUpdated: chargeStateLastUpdated,
            isConnected: isConnected,
            detail: detail,
            componentIdentity: resolvedComponentIdentity,
            alternateDeviceIdentities: alternateDeviceIdentities
        )
    }

    var clampedLevel: Int? {
        guard let level else {
            return nil
        }

        return min(max(level, 0), 100)
    }

    func isLowBattery(threshold: Int) -> Bool {
        guard let level = clampedLevel else {
            return false
        }

        return isConnected
            && level < threshold
            && chargeState != .charging
            && chargeState != .charged
            && chargeState != .plugged
    }

    var isDisplayLowBattery: Bool {
        guard let level = clampedLevel else {
            return false
        }

        return level <= DeviceBatteryLowBatteryThresholds.defaultValue
            && chargeState != .charging
            && chargeState != .charged
    }
}

enum DeviceBatteryItemNormalizer {
    static func resolvingAppleMobileDeviceAliases(
        _ items: [DeviceBatteryItem]
    ) -> [DeviceBatteryItem] {
        let mobileDeviceIndices = items.indices.filter { index in
            items[index].source == "MobileDevice"
                && items[index].deviceIdentity.namespace == .mobileDevice
                && items[index].kind.isAppleMobileDevice
        }
        let supplementalIndices = items.indices.filter { index in
            !mobileDeviceIndices.contains(index)
        }
        guard !mobileDeviceIndices.isEmpty, !supplementalIndices.isEmpty else {
            return items
        }

        let candidatesBySupplemental = Dictionary(
            uniqueKeysWithValues: supplementalIndices.map { supplementalIndex in
                let candidates = mobileDeviceIndices.filter { mobileDeviceIndex in
                    hasSharedDeviceIdentity(
                        items[supplementalIndex],
                        items[mobileDeviceIndex]
                    )
                }
                return (supplementalIndex, candidates)
            }
        )

        let resolvedIdentityByIndex = candidatesBySupplemental.reduce(
            into: [Int: DeviceBatteryDeviceIdentity]()
        ) { result, entry in
            guard entry.value.count == 1,
                  let mobileDeviceIndex = entry.value.first
            else {
                return
            }
            result[entry.key] = items[mobileDeviceIndex].deviceIdentity
        }

        return items.enumerated().map { index, item in
            guard let resolvedIdentity = resolvedIdentityByIndex[index] else {
                return item
            }
            return item.resolvingDeviceIdentity(to: resolvedIdentity)
        }
    }

    private static func hasSharedDeviceIdentity(
        _ supplementalItem: DeviceBatteryItem,
        _ mobileDeviceItem: DeviceBatteryItem
    ) -> Bool {
        !supplementalItem.allDeviceIdentities
            .isDisjoint(with: mobileDeviceItem.allDeviceIdentities)
    }

    static func removingComponentItems(
        _ items: [DeviceBatteryItem],
        forSingleBatteryDevices deviceIdentities: Set<DeviceBatteryDeviceIdentity>
    ) -> [DeviceBatteryItem] {
        guard !deviceIdentities.isEmpty else {
            return items
        }

        return items.filter { item in
            guard let identity = item.componentIdentity,
                  identity.role.isPart
            else {
                return true
            }
            return !deviceIdentities.contains(item.deviceIdentity)
        }
    }

    static func preferringDetailedComponents(
        _ items: [DeviceBatteryItem]
    ) -> [DeviceBatteryItem] {
        let rolesByDevice = items.reduce(
            into: [DeviceBatteryDeviceIdentity: Set<DeviceBatteryComponentRole>]()
        ) { result, item in
            guard item.clampedLevel != nil else {
                return
            }
            result[item.deviceIdentity, default: []].insert(item.batterySlot)
        }
        guard !rolesByDevice.isEmpty else {
            return items
        }

        return items.filter { item in
            guard item.clampedLevel != nil,
                  let deviceRoles = rolesByDevice[item.deviceIdentity]
            else {
                return true
            }

            let hasIndividualEarbuds = deviceRoles.contains(.left)
                && deviceRoles.contains(.right)
            switch item.batterySlot {
            case .aggregate:
                return !deviceRoles.contains(.earbuds)
                    && !hasIndividualEarbuds
            case .earbuds:
                return !hasIndividualEarbuds
            case .left, .right, .chargingCase:
                return true
            }
        }
    }
}

extension DeviceBatteryKind {
    var isAppleMobileDevice: Bool {
        switch self {
        case .phone, .tablet, .mediaPlayer, .watch, .spatialComputer:
            return true
        case .internalBattery, .bluetooth, .magicAccessory, .airPodsPart, .vendorHIDMouse, .other:
            return false
        }
    }
}

enum DeviceBatteryAccessState: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case noDevices
    case permissionDenied
    case failed(String)

    var isError: Bool {
        switch self {
        case .permissionDenied, .failed:
            return true
        case .idle, .scanning, .ready, .noDevices:
            return false
        }
    }
}

struct DeviceBatterySnapshot: Equatable, Sendable {
    var accessState: DeviceBatteryAccessState
    var items: [DeviceBatteryItem]
    var lastUpdated: Date?
    var vendorHIDState: VendorHIDBatteryAccessState

    static let idle = DeviceBatterySnapshot(
        accessState: .idle,
        items: [],
        lastUpdated: nil,
        vendorHIDState: .idle
    )

    var visibleItems: [DeviceBatteryItem] {
        items.sorted(by: Self.sortItems)
    }

    var primaryItem: DeviceBatteryItem? {
        visibleItems.first
    }

    var lowBatteryCount: Int {
        visibleItems.filter(\.isDisplayLowBattery).count
    }

    func lowBatteryItems(threshold: Int) -> [DeviceBatteryItem] {
        let normalizedThreshold = DeviceBatteryLowBatteryThresholds.normalized(threshold)
        return visibleItems.filter { $0.isLowBattery(threshold: normalizedThreshold) }
    }

    func subtitle(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch accessState {
        case .idle:
            return localization.string("snapshot.subtitle.idle", defaultValue: "等待检测")
        case .scanning:
            return localization.string("snapshot.subtitle.scanning", defaultValue: "正在读取设备电量")
        case .ready:
            if lowBatteryCount > 0 {
                return localization.format(
                    "snapshot.subtitle.readyWithLowBattery",
                    defaultValue: "%d 台设备，%d 台低电量",
                    visibleItems.count,
                    lowBatteryCount
                )
            }
            return localization.format(
                "snapshot.subtitle.ready",
                defaultValue: "%d 台设备",
                visibleItems.count
            )
        case .noDevices:
            return localization.string("snapshot.subtitle.noDevices", defaultValue: "未检测到可显示电量")
        case .permissionDenied:
            return localization.string("snapshot.subtitle.permissionDenied", defaultValue: "需要输入监控权限")
        case let .failed(message):
            return message
        }
    }

    func errorMessage(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String? {
        switch accessState {
        case .permissionDenied:
            return localization.string(
                "snapshot.error.permissionDenied",
                defaultValue: "无法访问厂商 HID 鼠标接口，请在系统设置中允许 MacTools 使用输入监控。"
            )
        case let .failed(message):
            return message
        case .idle, .scanning, .ready, .noDevices:
            return nil
        }
    }

    private static func sortItems(_ left: DeviceBatteryItem, _ right: DeviceBatteryItem) -> Bool {
        let leftRank = itemRank(left)
        let rightRank = itemRank(right)
        if leftRank != rightRank {
            return leftRank < rightRank
        }

        let nameOrder = left.name.localizedCompare(right.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return left.stableBatteryIdentityKey < right.stableBatteryIdentityKey
    }

    private static func itemRank(_ item: DeviceBatteryItem) -> Int {
        if item.isDisplayLowBattery {
            return 0
        }

        switch item.kind {
        case .internalBattery:
            return 1
        case .phone, .tablet, .mediaPlayer, .watch, .spatialComputer:
            return 2
        case .vendorHIDMouse:
            return 3
        case .magicAccessory:
            return 4
        case .airPodsPart:
            return 5
        case .bluetooth:
            return 6
        case .other:
            return 7
        }
    }
}

enum DeviceBatteryFormatter {
    static func percent(_ level: Int?) -> String {
        guard let level else {
            return "--"
        }

        return "\(min(max(level, 0), 100))%"
    }

    static func time(
        _ date: Date?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        guard let date else {
            return localization.string("time.notUpdated", defaultValue: "未更新")
        }

        timeFormatter.locale = PluginRuntimeLocalization.locale
        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
