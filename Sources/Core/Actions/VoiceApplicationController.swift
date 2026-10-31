import AppKit
import Foundation

struct VoiceApplicationTarget: Equatable, Sendable {
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let file: UInt64
    }
    let name: String
    let url: URL
    let bundleIdentifier: String?
    let fileIdentity: FileIdentity?

    init(name: String, url: URL, bundleIdentifier: String?, fileIdentity: FileIdentity? = nil) {
        self.name = name; self.url = url; self.bundleIdentifier = bundleIdentifier; self.fileIdentity = fileIdentity
    }

    var searchText: String {
        "\(name) \(url.deletingPathExtension().lastPathComponent) \(bundleIdentifier ?? "")".lowercased()
    }

    var location: String {
        let path = url.path
        if path.hasPrefix(NSHomeDirectory() + "/Applications/") { return "User Applications" }
        if path.hasPrefix("/Applications/") {
            let folder = url.deletingLastPathComponent().lastPathComponent
            return folder == "Applications" ? folder : "Applications / " + folder
        }
        if path.hasPrefix("/System/") { return "System Applications" }
        return "Running application"
    }
}

@MainActor
protocol VoiceApplicationControlling: AnyObject {
    func applications() async -> [VoiceApplicationTarget]
    func open(_ target: VoiceApplicationTarget) async throws
}

/// Local discovery does no icon work and never exposes application paths to the model.
@MainActor
final class SystemVoiceApplicationController: VoiceApplicationControlling {
    func applications() async -> [VoiceApplicationTarget] {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        return await Task.detached(priority: .userInitiated) {
            let installed = InstalledApplicationScanner.scan()
            var seen = Set<String>()
            return (installed.map(\.url) + running).compactMap { url in
                let url = url.resolvingSymlinksInPath()
                guard seen.insert(url.path).inserted else { return nil }
                return Self.target(at: url)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    func open(_ target: VoiceApplicationTarget) async throws {
        let current = await Task.detached(priority: .userInitiated) { Self.target(at: target.url) }.value
        try Task.checkCancellation()
        guard current?.url == target.url, current?.bundleIdentifier == target.bundleIdentifier,
              current?.fileIdentity == target.fileIdentity else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try await NSWorkspace.shared.openApplication(at: target.url, configuration: configuration)
    }

    nonisolated static func target(at url: URL) -> VoiceApplicationTarget? {
        guard url.isFileURL, url.pathExtension == "app",
              !InstalledApplicationScanner.isNestedInsideAnotherApp(url),
              InstalledApplicationScanner.isValidAppBundle(at: url.path),
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let name = InstalledApplicationScanner.displayName(for: url)
        guard !name.isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let identifier = bundle.bundleIdentifier.flatMap { $0.utf8.count <= 256 ? $0 : nil }
        return .init(name: name, url: url, bundleIdentifier: identifier,
                     fileIdentity: .init(device: device.uint64Value, file: file.uint64Value))
    }
}
