import AppKit
import ApplicationServices
import Foundation

struct ComputerTaskApplication: Sendable, Equatable {
    let pid: Int32
    let name: String
    let bundleID: String
    let launched: Date
}

@MainActor
protocol ComputerTaskEnvironment: AnyObject {
    func resolveApplications(_ names: [String]) throws -> [ComputerTaskApplication]
    func isRunning(_ app: ComputerTaskApplication) -> Bool
    func windows(_ app: ComputerTaskApplication) -> [ComputerUseTarget]
    func menus(_ target: ComputerUseTarget, path: [String]) async throws -> String
    func input(_ operation: ComputerTaskInput, target: ComputerUseTarget) async throws
    func stop()
}

enum ComputerTaskInput: Sendable {
    case key([String])
    case text(String)
    case menu(String)
}

@MainActor
final class SystemComputerTaskEnvironment: ComputerTaskEnvironment {
    private let native = ComputerTaskNativeInput()

    func resolveApplications(_ names: [String]) throws -> [ComputerTaskApplication] {
        guard !names.isEmpty, names.count <= 8 else { throw ComputerUseError.invalidParameters }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var result: [ComputerTaskApplication] = []
        for name in names {
            let exact = apps.filter {
                $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame
                    || $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
            }
            let matches = exact.isEmpty ? apps.filter {
                $0.localizedName?.localizedCaseInsensitiveContains(name) == true
            } : exact
            guard matches.count == 1, let app = matches.first,
                  let launched = ComputerTaskNativeInput.launchDate(app.processIdentifier) else {
                throw ComputerUseError.unavailable("Choose one running application for \(String(name.prefix(100))). Open it first if needed; ambiguous names require clarification.")
            }
            let entry = ComputerTaskApplication(pid: app.processIdentifier, name: app.localizedName ?? name,
                bundleID: app.bundleIdentifier ?? "", launched: launched)
            if !result.contains(entry) { result.append(entry) }
        }
        return result
    }

    func isRunning(_ app: ComputerTaskApplication) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else { return false }
        return ComputerTaskNativeInput.launchDate(app.pid) == app.launched
    }

    func windows(_ app: ComputerTaskApplication) -> [ComputerUseTarget] {
        guard isRunning(app) else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { row in
            guard row[kCGWindowOwnerPID as String] as? Int32 == app.pid,
                  row[kCGWindowLayer as String] as? Int == 0,
                  let id = row[kCGWindowNumber as String] as? Int else { return nil }
            return .init(pid: app.pid, windowID: id, name: app.name, launched: app.launched,
                windowTitle: row[kCGWindowName as String] as? String ?? "")
        }
    }

    func menus(_ target: ComputerUseTarget, path: [String]) async throws -> String {
        try await native.menus(target, path: path)
    }

    func input(_ operation: ComputerTaskInput, target: ComputerUseTarget) async throws {
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              ComputerTaskNativeInput.launchDate(target.pid) == target.launched else { throw ComputerUseError.invalidTarget }
        // Activation is explicit and limited to the app in the approved task.
        app.activate(options: [])
        try await native.input(operation, target: target)
    }

    func stop() { native.stop() }
}
