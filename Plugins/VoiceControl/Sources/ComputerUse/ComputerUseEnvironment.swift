import AppKit
import ApplicationServices
import Darwin
import Foundation

struct ComputerUseTarget: Equatable, Sendable {
    let pid: Int32
    let windowID: Int
    let name: String
    let launched: Date
    let windowTitle: String

    init(pid: Int32, windowID: Int, name: String, launched: Date, windowTitle: String = "") {
        self.pid = pid; self.windowID = windowID; self.name = name
        self.launched = launched; self.windowTitle = windowTitle
    }
}

@MainActor
protocol ComputerUseEnvironment: AnyObject {
    func resolve(app: String, windowID: Int?) throws -> ComputerUseTarget
    func isCurrent(_ target: ComputerUseTarget) -> Bool
    func copy(_ text: String) throws
    func open(_ url: URL, browser: String?) async throws
}

@MainActor
final class SystemComputerUseEnvironment: ComputerUseEnvironment {
    private static let browsers = [
        "chrome": "com.google.Chrome", "google chrome": "com.google.Chrome",
        "safari": "com.apple.Safari", "firefox": "org.mozilla.firefox",
        "edge": "com.microsoft.edgemac", "microsoft edge": "com.microsoft.edgemac",
        "brave": "com.brave.Browser", "arc": "company.thebrowser.Browser"
    ]

    func resolve(app: String, windowID: Int?) throws -> ComputerUseTarget {
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
                && ($0.bundleIdentifier?.caseInsensitiveCompare(app) == .orderedSame
                    || $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame)
        }
        guard matches.count == 1, let application = matches.first,
              let launched = launchDate(application.processIdentifier),
              let window = windows().first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier
                      && (windowID == nil || $0[kCGWindowNumber as String] as? Int == windowID)
              }), let id = window[kCGWindowNumber as String] as? Int else {
            throw ComputerUseError.invalidTarget
        }
        return .init(pid: application.processIdentifier, windowID: id,
                     name: application.localizedName ?? app, launched: launched,
                     windowTitle: window[kCGWindowName as String] as? String ?? "")
    }

    func isCurrent(_ target: ComputerUseTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              launchDate(target.pid) == target.launched else { return false }
        return windows().contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid
                && ($0[kCGWindowNumber as String] as? Int) == target.windowID
        }
    }

    private func windows() -> [[String: Any]] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return (info as? [[String: Any]] ?? []).filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private func launchDate(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    func copy(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else {
            throw ComputerUseError.unverified
        }
    }

    func open(_ url: URL, browser: String?) async throws {
        let selection = browser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application: URL
        if selection.isEmpty || selection.caseInsensitiveCompare("default") == .orderedSame {
            guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { throw ComputerUseError.invalidTarget }
            application = handler
        } else {
            let identifier = Self.browsers[selection.lowercased()] ?? selection
            guard !identifier.contains("/"), let handler = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                throw ComputerUseError.invalidTarget
            }
            application = handler
        }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
    }
}
