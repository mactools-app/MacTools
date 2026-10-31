import Foundation

/// Lifecycle state of the `container` system service.
public enum ContainerServiceStatus: String, Sendable, Equatable {
    case running
    case stopped
    case unregistered
    case unknown
}

/// Static configuration reported by `container list`, shown in the detail
/// window. Every field is optional in the CLI output, so the parser keeps
/// neutral defaults instead of failing the whole entry.
public struct ContainerConfiguration: Hashable, Sendable {
    public let command: String
    public let workingDirectory: String
    public let user: String
    /// Environment variable names only. Values stay out of the UI because
    /// `container inspect` exposes secrets such as database passwords.
    public let environmentKeys: [String]
    public let ports: [String]
    public let mounts: [String]
    public let networks: [String]
    public let hostname: String
    public let dnsDomain: String
    public let dnsServers: [String]
    public let platform: String
    public let runtimeHandler: String
    public let readOnly: Bool
    public let rosetta: Bool
    public let ssh: Bool
    public let imageDigest: String
    public let createdAt: Date?
    /// Optional storage quota from `configuration.resources.storage`.
    public let storageQuotaBytes: Int?

    public static let empty = ContainerConfiguration(
        command: "",
        workingDirectory: "",
        user: "",
        environmentKeys: [],
        ports: [],
        mounts: [],
        networks: [],
        hostname: "",
        dnsDomain: "",
        dnsServers: [],
        platform: "",
        runtimeHandler: "",
        readOnly: false,
        rosetta: false,
        ssh: false,
        imageDigest: "",
        createdAt: nil,
        storageQuotaBytes: nil
    )

    public init(
        command: String,
        workingDirectory: String,
        user: String,
        environmentKeys: [String],
        ports: [String],
        mounts: [String],
        networks: [String],
        hostname: String,
        dnsDomain: String,
        dnsServers: [String],
        platform: String,
        runtimeHandler: String,
        readOnly: Bool,
        rosetta: Bool,
        ssh: Bool,
        imageDigest: String,
        createdAt: Date?,
        storageQuotaBytes: Int?
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.user = user
        self.environmentKeys = environmentKeys
        self.ports = ports
        self.mounts = mounts
        self.networks = networks
        self.hostname = hostname
        self.dnsDomain = dnsDomain
        self.dnsServers = dnsServers
        self.platform = platform
        self.runtimeHandler = runtimeHandler
        self.readOnly = readOnly
        self.rosetta = rosetta
        self.ssh = ssh
        self.imageDigest = imageDigest
        self.createdAt = createdAt
        self.storageQuotaBytes = storageQuotaBytes
    }
}

/// One reduced sample of a running container's live resource usage. Rates are
/// nil until two daemon samples exist (or when a counter reset), so the card
/// can show "—" instead of a fabricated zero.
public struct ContainerPerformance: Hashable, Sendable {
    /// Percentage of the container's configured CPU allotment, so 100% means
    /// every configured core is busy.
    public let cpuPercent: Double?
    public let memoryBytes: Int?
    public let memoryLimitBytes: Int?
    public let diskReadBytesPerSecond: Double?
    public let diskWriteBytesPerSecond: Double?
    public let sampledAt: Date

    public var diskTotalBytesPerSecond: Double? {
        guard let read = diskReadBytesPerSecond,
              let write = diskWriteBytesPerSecond else {
            return nil
        }
        return read + write
    }

    public init(
        cpuPercent: Double?,
        memoryBytes: Int?,
        memoryLimitBytes: Int?,
        diskReadBytesPerSecond: Double?,
        diskWriteBytesPerSecond: Double?,
        sampledAt: Date
    ) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.sampledAt = sampledAt
    }
}

/// A container instance reported by `container list`.
public struct ContainerInstance: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var statusText: String
    public var image: String
    /// Configured core count from `configuration.resources.cpus`.
    public var cpus: Int
    /// Configured memory limit from `configuration.resources.memoryInBytes`.
    public var memoryBytes: Int
    /// Container platform architecture, used to pick the matching image size.
    public var architecture: String
    /// On-disk size of the matching image variant, resolved from
    /// `container image list`; nil while no match is available.
    public var imageStorageBytes: Int?
    public var configuration: ContainerConfiguration
    /// Latest live sample; only running containers receive one.
    public var performance: ContainerPerformance?

    public var isRunning: Bool {
        statusText.lowercased() == "running"
    }

    public init(
        id: String,
        name: String,
        statusText: String,
        image: String,
        cpus: Int = 0,
        memoryBytes: Int = 0,
        architecture: String = "",
        imageStorageBytes: Int? = nil,
        configuration: ContainerConfiguration = .empty,
        performance: ContainerPerformance? = nil
    ) {
        self.id = id
        self.name = name
        self.statusText = statusText
        self.image = image
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.architecture = architecture
        self.imageStorageBytes = imageStorageBytes
        self.configuration = configuration
        self.performance = performance
    }

    /// Returns a copy carrying the resolved image storage size.
    public func withImageStorage(_ bytes: Int?) -> ContainerInstance {
        var copy = self
        copy.imageStorageBytes = bytes
        return copy
    }

    /// Returns a copy carrying the latest live sample.
    public func withPerformance(_ performance: ContainerPerformance?) -> ContainerInstance {
        var copy = self
        copy.performance = performance
        return copy
    }
}

/// A virtual machine reported by `container machine list`.
public struct ContainerMachine: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let statusText: String
    public let isDefault: Bool
    /// Virtual CPU count from `cpus`.
    public let cpus: Int
    /// Memory size from `memory` (bytes).
    public let memoryBytes: Int
    /// Disk image size from `diskSize` (bytes).
    public let diskSizeBytes: Int
    /// Boot image reference resolved from `container machine inspect`;
    /// empty until an inspect succeeded.
    public let image: String

    public var isRunning: Bool {
        statusText.lowercased() == "running"
    }

    public init(
        id: String,
        name: String,
        statusText: String,
        isDefault: Bool,
        cpus: Int = 0,
        memoryBytes: Int = 0,
        diskSizeBytes: Int = 0,
        image: String = ""
    ) {
        self.id = id
        self.name = name
        self.statusText = statusText
        self.isDefault = isDefault
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskSizeBytes = diskSizeBytes
        self.image = image
    }

    /// Returns a copy carrying the resolved boot image reference.
    public func withImage(_ image: String) -> ContainerMachine {
        ContainerMachine(
            id: id,
            name: name,
            statusText: statusText,
            isDefault: isDefault,
            cpus: cpus,
            memoryBytes: memoryBytes,
            diskSizeBytes: diskSizeBytes,
            image: image
        )
    }
}

/// Byte sizes and live rates rendered for panel copy: whole units below GB,
/// one decimal above.
public enum ContainerIndicatorFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    public static func bytes(_ byteCount: Int) -> String {
        guard byteCount > 0 else { return "-" }
        var value = Double(byteCount)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index >= 3 {
            return String(format: "%.1f %@", value, units[index])
        }
        return String(format: "%.0f %@", value, units[index])
    }

    /// Throughput for the live line, e.g. `1.2 MB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "-" }
        return String(format: "%.0f%%", max(0, value))
    }

    /// The full image reference while it fits; once it is too long for the
    /// column, only its last path segment stays visible. The full reference
    /// remains available through the row's hover help.
    public static func imageLabel(for reference: String, fits: Bool) -> String {
        guard !fits, reference.contains("/") else { return reference }
        return reference.split(separator: "/").last.map(String.init) ?? reference
    }
}

/// Immutable result of one status check, shared by every panel surface.
public struct ContainerSnapshot: Equatable, Sendable {
    public let status: ContainerServiceStatus
    public let containers: [ContainerInstance]
    public let machines: [ContainerMachine]
    public let updatedAt: Date?
    /// Why the latest `container list` read failed. The entries then come from
    /// the last successful read, so the card must not present them as current
    /// or fall back to an empty-list message.
    public let containersFailure: String?
    /// Same as `containersFailure`, for `container machine list`.
    public let machinesFailure: String?
    /// Why the latest `container stats` read failed. The live numbers then come
    /// from the previous sample, so the card marks them as stale.
    public let statsFailure: String?

    public static let unavailable = ContainerSnapshot(
        status: .unknown,
        containers: [],
        machines: [],
        updatedAt: nil
    )

    public init(
        status: ContainerServiceStatus,
        containers: [ContainerInstance],
        machines: [ContainerMachine],
        updatedAt: Date?,
        containersFailure: String? = nil,
        machinesFailure: String? = nil,
        statsFailure: String? = nil
    ) {
        self.status = status
        self.containers = containers
        self.machines = machines
        self.updatedAt = updatedAt
        self.containersFailure = containersFailure
        self.machinesFailure = machinesFailure
        self.statsFailure = statsFailure
    }

    public var runningContainerCount: Int {
        containers.filter(\.isRunning).count
    }

    public var runningMachineCount: Int {
        machines.filter(\.isRunning).count
    }
}

/// Pure JSON parsing kept separate from process execution so state derivation
/// stays testable without the real `container` command-line tool.
public enum ContainerIndicatorParser {
    public static func serviceStatus(exitCode: Int32, output: String) -> ContainerServiceStatus {
        guard exitCode == 0 else {
            // The `container` CLI reports a stopped service with exit code 1.
            return exitCode == 1 ? .stopped : .unknown
        }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            return .unknown
        }

        return ContainerServiceStatus(rawValue: status) ?? .unknown
    }

    public static func containers(fromJSON output: String) -> [ContainerInstance] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> ContainerInstance? in
            guard let id = entry["id"] as? String else { return nil }

            let configuration = entry["configuration"] as? [String: Any]
            let name = configuration?["id"] as? String ?? id
            let image = configuration?["image"] as? [String: Any]
            let imageReference = image?["reference"] as? String ?? ""
            let status = entry["status"] as? [String: Any]
            let state = status?["state"] as? String ?? ""
            let resources = configuration?["resources"] as? [String: Any]
            let platform = configuration?["platform"] as? [String: Any]

            return ContainerInstance(
                id: id,
                name: name,
                statusText: state,
                image: imageReference,
                cpus: resources?["cpus"] as? Int ?? 0,
                memoryBytes: resources?["memoryInBytes"] as? Int ?? 0,
                architecture: platform?["architecture"] as? String ?? "",
                configuration: Self.configuration(from: configuration)
            )
        }
    }

    /// Reads the cumulative counters from `container stats --format json`.
    /// CPU percentage and throughput are derived later from two samples.
    public static func stats(fromJSON output: String) -> [String: ContainerStatsCounters] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var counters: [String: ContainerStatsCounters] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            counters[id] = ContainerStatsCounters(
                id: id,
                cpuUsageUsec: unsigned(entry["cpuUsageUsec"]),
                memoryUsageBytes: unsigned(entry["memoryUsageBytes"]),
                memoryLimitBytes: unsigned(entry["memoryLimitBytes"]),
                blockReadBytes: unsigned(entry["blockReadBytes"]),
                blockWriteBytes: unsigned(entry["blockWriteBytes"]),
                networkRxBytes: unsigned(entry["networkRxBytes"]),
                networkTxBytes: unsigned(entry["networkTxBytes"]),
                numProcesses: unsigned(entry["numProcesses"])
            )
        }
        return counters
    }

    public static func machines(fromJSON output: String) -> [ContainerMachine] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> ContainerMachine? in
            guard let id = entry["id"] as? String else { return nil }

            return ContainerMachine(
                id: id,
                name: id,
                statusText: entry["status"] as? String ?? "",
                isDefault: entry["default"] as? Bool ?? false,
                cpus: entry["cpus"] as? Int ?? 0,
                memoryBytes: entry["memory"] as? Int ?? 0,
                diskSizeBytes: entry["diskSize"] as? Int ?? 0
            )
        }
    }

    /// Reads the boot image reference from `container machine inspect` output,
    /// which is an array whose first entry carries `image.reference`.
    public static func machineImage(fromInspectJSON output: String) -> String {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = entries.first else {
            return ""
        }

        let image = first["image"] as? [String: Any]
        return image?["reference"] as? String ?? ""
    }

    /// Maps image reference to architecture to variant size from
    /// `container image list`, so each container can show the storage size of
    /// the image variant it actually runs.
    public static func imageStorageSizes(fromJSON output: String) -> [String: [String: Int]] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var result: [String: [String: Int]] = [:]
        for entry in entries {
            let configuration = entry["configuration"] as? [String: Any]
            guard let name = configuration?["name"] as? String,
                  let variants = entry["variants"] as? [[String: Any]] else { continue }

            var sizesByArchitecture = result[name] ?? [:]
            for variant in variants {
                guard let size = variant["size"] as? Int else { continue }
                let variantConfig = variant["config"] as? [String: Any]
                let architecture = variantConfig?["architecture"] as? String ?? ""
                sizesByArchitecture[architecture] = max(sizesByArchitecture[architecture] ?? 0, size)
            }
            if !sizesByArchitecture.isEmpty {
                result[name] = sizesByArchitecture
            }
        }
        return result
    }

    // MARK: - Configuration

    private static func configuration(from configuration: [String: Any]?) -> ContainerConfiguration {
        guard let configuration else { return .empty }

        let initProcess = configuration["initProcess"] as? [String: Any] ?? [:]
        let executable = initProcess["executable"] as? String ?? ""
        let arguments = initProcess["arguments"] as? [String] ?? []
        let command = ([executable] + arguments)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let environment = initProcess["environment"] as? [String] ?? []
        let environmentKeys = environment.compactMap { item in
            item.split(separator: "=", maxSplits: 1).first.map(String.init)
        }

        let networks = configuration["networks"] as? [[String: Any]] ?? []
        let networkNames = networks.compactMap { $0["network"] as? String }
        let networkOptions = networks.first?["options"] as? [String: Any] ?? [:]

        let dns = configuration["dns"] as? [String: Any] ?? [:]
        let platform = configuration["platform"] as? [String: Any] ?? [:]
        let platformOS = platform["os"] as? String ?? ""
        let platformArchitecture = platform["architecture"] as? String ?? ""

        let image = configuration["image"] as? [String: Any] ?? [:]
        let descriptor = image["descriptor"] as? [String: Any] ?? [:]

        let resources = configuration["resources"] as? [String: Any] ?? [:]

        return ContainerConfiguration(
            command: command,
            workingDirectory: initProcess["workingDirectory"] as? String ?? "",
            user: userDescription(initProcess["user"]),
            environmentKeys: environmentKeys,
            ports: portDescriptions(configuration["publishedPorts"]),
            mounts: mountDescriptions(configuration["mounts"]),
            networks: networkNames,
            hostname: networkOptions["hostname"] as? String ?? "",
            dnsDomain: dns["domain"] as? String ?? "",
            dnsServers: dns["nameservers"] as? [String] ?? [],
            platform: [platformOS, platformArchitecture]
                .filter { !$0.isEmpty }
                .joined(separator: "/"),
            runtimeHandler: configuration["runtimeHandler"] as? String ?? "",
            readOnly: configuration["readOnly"] as? Bool ?? false,
            rosetta: configuration["rosetta"] as? Bool ?? false,
            ssh: configuration["ssh"] as? Bool ?? false,
            imageDigest: descriptor["digest"] as? String ?? "",
            createdAt: date(configuration["creationDate"]),
            storageQuotaBytes: integer(resources["storage"])
        )
    }

    /// `user` is either `{id: {uid, gid}}` or `{raw: {userString}}`.
    private static func userDescription(_ value: Any?) -> String {
        guard let user = value as? [String: Any] else { return "" }
        if let raw = user["raw"] as? [String: Any],
           let userString = raw["userString"] as? String,
           !userString.isEmpty {
            return userString
        }
        if let id = user["id"] as? [String: Any],
           let uid = integer(id["uid"]),
           let gid = integer(id["gid"]) {
            return "\(uid):\(gid)"
        }
        return ""
    }

    private static func portDescriptions(_ value: Any?) -> [String] {
        guard let ports = value as? [[String: Any]] else { return [] }
        return ports.map { port in
            let hostAddress = port["hostAddress"] as? String ?? ""
            let hostPort = integer(port["hostPort"]) ?? 0
            let containerPort = integer(port["containerPort"]) ?? 0
            let proto = port["proto"] as? String ?? "tcp"
            let host = hostAddress.isEmpty ? "\(hostPort)" : "\(hostAddress):\(hostPort)"
            return "\(host) → \(containerPort)/\(proto)"
        }
    }

    private static func mountDescriptions(_ value: Any?) -> [String] {
        guard let mounts = value as? [[String: Any]] else { return [] }
        return mounts.map { mount in
            let source = mount["source"] as? String ?? ""
            let destination = mount["destination"] as? String ?? ""
            if source.isEmpty { return destination }
            if destination.isEmpty { return source }
            return "\(source) → \(destination)"
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        return number.uint64Value
    }
}
