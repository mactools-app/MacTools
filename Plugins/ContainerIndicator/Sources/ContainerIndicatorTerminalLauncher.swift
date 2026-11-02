import AppKit
import Darwin
import Foundation

/// A running resource that can open an interactive shell.
public enum ContainerTerminalTarget: Equatable, Sendable {
    case container(id: String)
    case machine(id: String)

    public var identifier: String {
        switch self {
        case .container(let id), .machine(let id):
            return id
        }
    }
}

public enum ContainerTerminalLaunchError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidExecutable
    case scriptWriteFailed
    case openFailed
}

@MainActor
public protocol ContainerTerminalLaunching {
    func launch(
        target: ContainerTerminalTarget,
        executable: String,
        application: ContainerTerminalApplication
    ) async throws
}

/// Opens an interactive shell in the user's selected terminal. The plugin runs
/// inside the host app and has no PTY, so it writes a small `.command` script
/// and hands it to LaunchServices: that avoids AppleScript automation prompts
/// and keeps the terminal window attached to the user's own session.
///
/// Launching talks to another application and can take seconds or hang, so the
/// blocking work runs off the main thread behind a timeout.
@MainActor
public struct ContainerTerminalLauncher: ContainerTerminalLaunching {
    /// Container and machine identifiers are user-chosen names; anything
    /// outside this set never reaches the script.
    private static let identifierPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    /// A terminal that has not accepted the script by now is treated as failed
    /// instead of keeping the action pending forever.
    public static let launchTimeout: TimeInterval = 10

    private let directory: URL
    private let fileManager: FileManager
    private let applicationResolver: (ContainerTerminalApplication) -> URL?
    private let defaultApplicationResolver: (URL) -> URL?
    private let runOpen: ([String]) async -> Bool
    private let runAppleScript: (String) async -> Bool

    public init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTools/ContainerIndicator/Terminal", isDirectory: true),
        fileManager: FileManager = .default,
        applicationResolver: @escaping (ContainerTerminalApplication) -> URL? = {
            ContainerTerminalApplicationCatalog.applicationURL(for: $0)
        },
        defaultApplicationResolver: ((URL) -> URL?)? = nil,
        runOpen: (([String]) async -> Bool)? = nil,
        runAppleScript: ((String) async -> Bool)? = nil
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.applicationResolver = applicationResolver
        self.defaultApplicationResolver = defaultApplicationResolver
            ?? { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        self.runOpen = runOpen ?? { arguments in
            await ContainerTerminalLauncher.runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: arguments,
                timeout: ContainerTerminalLauncher.launchTimeout
            )
        }
        self.runAppleScript = runAppleScript ?? { source in
            await ContainerTerminalLauncher.executeAppleScript(
                source,
                timeout: ContainerTerminalLauncher.launchTimeout
            )
        }
    }

    public func launch(
        target: ContainerTerminalTarget,
        executable: String,
        application: ContainerTerminalApplication
    ) async throws {
        guard Self.isValidIdentifier(target.identifier) else {
            throw ContainerTerminalLaunchError.invalidIdentifier
        }
        guard Self.isValidExecutablePath(executable) else {
            throw ContainerTerminalLaunchError.invalidExecutable
        }

        let script = Self.script(for: target, executable: executable)
        let fileURL = directory.appendingPathComponent(Self.fileName(for: target))

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try Data(script.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw ContainerTerminalLaunchError.scriptWriteFailed
        }

        let resolvedApplication: ContainerTerminalApplication
        if application == .systemDefault {
            resolvedApplication = defaultApplicationResolver(fileURL)
                .flatMap(ContainerTerminalApplication.init(applicationURL:))
                ?? .systemDefault
        } else {
            resolvedApplication = application
        }
        let applicationURL = resolvedApplication == .systemDefault
            ? nil
            : applicationResolver(resolvedApplication)
        // An app removed since the setting was saved falls back to the system
        // default instead of failing the whole terminal action.
        let effectiveApplication = applicationURL == nil ? .systemDefault : resolvedApplication

        // Ghostty and iTerm expose scripting commands for opening a tab in the
        // existing window. Terminal.app has no equivalent command, so it keeps
        // the document-based launch path.
        if let source = Self.appleScript(
            application: effectiveApplication,
            scriptURL: fileURL
        ) {
            guard await runAppleScript(source) else {
                throw ContainerTerminalLaunchError.openFailed
            }
            return
        }

        let arguments = Self.openArguments(
            application: effectiveApplication,
            applicationURL: applicationURL,
            scriptURL: fileURL
        )

        guard await runOpen(arguments) else {
            throw ContainerTerminalLaunchError.openFailed
        }
    }

    // MARK: - Off-main launch

    /// Runs a short-lived helper without blocking the caller. The continuation
    /// is resumed by whichever finishes first: the process or the timeout. A
    /// timed-out process is terminated, then force-killed if it ignores SIGTERM.
    static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = TerminalLaunchCompletion()
            let box = TerminalProcessBox()
            let process = box.process
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                completion.resume(continuation, value: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                completion.resume(continuation, value: false)
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                let process = box.process
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                        let process = box.process
                        if process.isRunning {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
                completion.resume(continuation, value: false)
            }
        }
    }

    /// NSAppleScript blocks until the target app answers, so the script runs as
    /// an `osascript` subprocess that can be stopped when it exceeds the
    /// timeout instead of lingering behind a reported failure.
    private static func executeAppleScript(_ source: String, timeout: TimeInterval) async -> Bool {
        await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", source],
            timeout: timeout
        )
    }

    /// AppleScript that opens a new tab when the terminal already has a
    /// window, and a first window when it does not.
    public static func appleScript(
        application: ContainerTerminalApplication,
        scriptURL: URL
    ) -> String? {
        let command = appleScriptQuoted(scriptURL.path)

        switch application {
        case .ghostty:
            return """
            tell application "Ghostty"
              activate
              set cfg to new surface configuration
              set command of cfg to "\(command)"
              if (count of windows) = 0 then
                set win to new window with configuration cfg
              else
                set win to front window
                set t to new tab in win with configuration cfg
                select tab t
              end if
            end tell
            """
        case .iterm:
            return """
            tell application "iTerm"
              activate
              if (count of windows) = 0 then
                create window with default profile command "\(command)"
              else
                tell current window
                  create tab with default profile command "\(command)"
                end tell
              end if
            end tell
            """
        default:
            return nil
        }
    }

    static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The arguments handed to `/usr/bin/open`. Explicit applications use
    /// their bundle path so a same-named app elsewhere cannot intercept the
    /// launch, and terminals that only accept a command line get `--args`.
    public static func openArguments(
        application: ContainerTerminalApplication,
        applicationURL: URL?,
        scriptURL: URL
    ) -> [String] {
        guard application != .systemDefault, let applicationURL else {
            return [scriptURL.path]
        }

        switch application {
        case .systemDefault:
            return [scriptURL.path]
        case .terminal, .iterm:
            // Both are document-based: opening the `.command` file runs it.
            return ["-a", applicationURL.path, scriptURL.path]
        case .ghostty:
            return ["-na", applicationURL.path, "--args", "-e", scriptURL.path]
        case .wezterm:
            return ["-na", applicationURL.path, "--args", "start", "--", scriptURL.path]
        case .kitty:
            return ["-na", applicationURL.path, "--args", scriptURL.path]
        case .alacritty:
            return ["-na", applicationURL.path, "--args", "-e", scriptURL.path]
        }
    }

    /// The script content, exposed for tests. It prefers bash when the image
    /// has it and falls back to the POSIX shell.
    public static func script(
        for target: ContainerTerminalTarget,
        executable: String
    ) -> String {
        let container = shellQuoted(executable)
        let identifier = shellQuoted(target.identifier)

        switch target {
        case .container:
            return """
            #!/bin/zsh
            CONTAINER=\(container)
            ID=\(identifier)
            if "$CONTAINER" exec "$ID" /bin/sh -c 'test -x /bin/bash' >/dev/null 2>&1; then
              exec "$CONTAINER" exec -it "$ID" /bin/bash
            fi
            exec "$CONTAINER" exec -it "$ID" /bin/sh
            """
        case .machine:
            return """
            #!/bin/zsh
            exec \(container) machine run -n \(identifier)
            """
        }
    }

    /// Single-quote shell escaping: wrap in quotes and splice embedded quotes
    /// as `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: identifierPattern, options: .regularExpression) != nil
    }

    static func isValidExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.contains("\n")
            && !path.contains("\r")
            && !path.contains("\0")
    }

    private static func fileName(for target: ContainerTerminalTarget) -> String {
        let prefix: String
        switch target {
        case .container: prefix = "container"
        case .machine: prefix = "machine"
        }
        let sanitized = target.identifier.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        return "\(prefix)-\(sanitized).command"
    }
}

/// Resumes a checked continuation exactly once. The process and the timeout
/// both try to finish the launch, and a second resume would trap.
private final class TerminalLaunchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(returning: value)
    }
}

/// `Process` is not `Sendable`, but the timeout closure only needs to ask
/// whether it is still running and stop it.
private final class TerminalProcessBox: @unchecked Sendable {
    let process = Process()
}
