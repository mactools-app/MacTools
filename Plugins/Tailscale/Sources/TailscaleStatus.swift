import Foundation
import Darwin
import Network

enum TailscaleConnectionState: Equatable {
    case checking, cliUnavailable, clientUnavailable, failed
    case running, stopped, needsLogin

    var canToggle: Bool { self == .running || self == .stopped }
}

struct TailscaleStatus: Equatable {
    struct Device: Decodable, Equatable, Identifiable {
        let stableID: String?
        let hostName: String?
        let dnsName: String?
        let addresses: [String]?
        let online: Bool?
        let exitNodeOption: Bool?
        let isExitNode: Bool?

        enum CodingKeys: String, CodingKey {
            case stableID = "ID", hostName = "HostName", dnsName = "DNSName"
            case addresses = "TailscaleIPs", online = "Online"
            case exitNodeOption = "ExitNodeOption", isExitNode = "ExitNode"
        }

        var id: String { stableID ?? "" }
        var name: String { [hostName, magicDNSName, ips.first].compactMap { $0 }.first { !$0.isEmpty } ?? id }
        var magicDNSName: String? {
            guard let dnsName else { return nil }
            let name = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
            return name.isEmpty ? nil : name
        }
        var ips: [String] { addresses ?? [] }
        var commandAddress: String? { ips.first { IPv4Address($0) != nil || IPv6Address($0) != nil } }
        var canUseAsExitNode: Bool { exitNodeOption == true && online == true && commandAddress != nil }
    }

    let connection: TailscaleConnectionState
    var local: Device? = nil
    var peers: [Device] = []
    var magicDNSEnabled = true
    var exitNode: ExitNode?
    var loginURL: URL?

    struct ExitNode: Decodable, Equatable {
        let id: String
        let online: Bool?

        enum CodingKeys: String, CodingKey { case id = "ID", online = "Online" }
    }

    private struct Payload: Decodable {
        struct Tailnet: Decodable {
            let MagicDNSEnabled: Bool?
        }

        let BackendState: String
        let AuthURL: String?
        let CurrentTailnet: Tailnet?
        let local: Device?
        let Peer: [String: Device]?
        let ExitNodeStatus: ExitNode?

        enum CodingKeys: String, CodingKey {
            case BackendState, AuthURL, CurrentTailnet, Peer, ExitNodeStatus
            case local = "Self"
        }
    }

    init(connection: TailscaleConnectionState) {
        self.connection = connection
    }

    init(result: TailscaleCommandResult) {
        if result.failure == .clientUnavailable {
            self.init(connection: .clientUnavailable)
            return
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: result.output) else {
            self.init(connection: result.failure == .needsLogin ? .needsLogin : .failed)
            return
        }
        switch payload.BackendState {
        case "Running" where result.succeeded:
            self.init(connection: .running)
            local = payload.local
            magicDNSEnabled = payload.CurrentTailnet?.MagicDNSEnabled ?? true
            var seen = Set<String>()
            peers = (payload.Peer ?? [:]).sorted { $0.key < $1.key }.map(\.value)
                .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
                .sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
            exitNode = payload.ExitNodeStatus ?? peers.first(where: { $0.isExitNode == true }).map {
                ExitNode(id: $0.id, online: $0.online)
            }
        case "Stopped": self.init(connection: .stopped)
        case "NeedsLogin", "NeedsMachineAuth", "NoState":
            self.init(connection: .needsLogin)
            if let value = payload.AuthURL,
               let components = URLComponents(string: value),
               components.scheme == "https", components.host == "login.tailscale.com",
               components.user == nil, components.password == nil, components.port == nil,
               components.path.hasPrefix("/a/"), components.path.count > 3 {
                loginURL = components.url
            }
        case "Starting" where result.succeeded: self.init(connection: .checking)
        default: self.init(connection: .failed)
        }
    }
}

enum TailscalePingResult: Equatable {
    case direct, derp, peerRelay, reachable, noReply, failed

    init(_ result: TailscaleCommandResult) {
        let output = String(decoding: result.output, as: UTF8.self)
        let routes = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("pong from "), let start = line.range(of: ") via "),
                  let end = line.range(of: " in ", options: .backwards), start.upperBound < end.lowerBound else {
                return nil
            }
            return String(line[start.upperBound..<end.lowerBound])
        }
        if routes.contains(where: Self.isDirectEndpoint) {
            self = .direct
        } else if let last = routes.last {
            if last.hasPrefix("DERP(") { self = .derp }
            else if last.hasPrefix("peer-relay(") { self = .peerRelay }
            else { self = .reachable }
        } else if output.contains(" timed out") || result.error.lowercased().contains("no reply") {
            self = .noReply
        } else {
            self = .failed
        }
    }

    private static func isDirectEndpoint(_ route: String) -> Bool {
        guard let separator = route.lastIndex(of: ":"), UInt16(route[route.index(after: separator)...]) != nil else {
            return false
        }
        let host = route[..<separator].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return IPv4Address(host) != nil || IPv6Address(host) != nil
    }
}

struct TailscaleCommandResult: Sendable {
    enum Failure { case clientUnavailable, needsLogin, command }

    let succeeded: Bool
    var output = Data()
    var error = ""

    var failure: Failure? {
        guard !succeeded else { return nil }
        let message = error.lowercased()
        if message.contains("failed to connect to local tailscaled")
            || message.contains("failed to connect to local tailscale service")
            || message.contains("is tailscaled running?")
            || message.contains("tailscale is not running") {
            return .clientUnavailable
        }
        if message.contains("logged out") || message.contains("not logged in") {
            return .needsLogin
        }
        return .command
    }
}

enum TailscaleCLI {
    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ arguments: [String]) async -> TailscaleCommandResult {
        let worker = Task.detached(priority: .utility) {
            (try? runSynchronously(path, arguments)) ?? TailscaleCommandResult(succeeded: false)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runSynchronously(_ path: String, _ arguments: [String]) throws -> TailscaleCommandResult {
        guard !Task.isCancelled else { return TailscaleCommandResult(succeeded: false) }
        // Unlinked files let the CLI write large peer lists without blocking on full pipes.
        let output = try makeCaptureFile()
        defer { try? output.close() }
        let error = try makeCaptureFile()
        defer { try? error.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()

        let deadline = DispatchTime.now() + (arguments.first == "status" ? 5 : 15)
        while completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if Task.isCancelled || DispatchTime.now() >= deadline {
                process.terminate()
                if completion.wait(timeout: .now() + .milliseconds(500)) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return TailscaleCommandResult(succeeded: false)
            }
        }
        try output.seek(toOffset: 0)
        try error.seek(toOffset: 0)
        return TailscaleCommandResult(
            succeeded: process.terminationStatus == 0,
            output: try output.readToEnd() ?? Data(),
            error: String(decoding: try error.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
        )
    }

    private static func makeCaptureFile() throws -> FileHandle {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-tailscale.XXXXXX").path
        var template = Array(path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard unlink(&template) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
