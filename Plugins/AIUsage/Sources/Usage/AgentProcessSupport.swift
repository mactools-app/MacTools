// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import Darwin
import Foundation

/// Cancellation owns one process launch; the lock closes the gap between
/// cancelling a queued request and that request launching its child.
final class BoundedProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let child = process
        lock.unlock()
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func launch(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, process == nil else { throw CancellationError() }
        try child.run()
        process = child
    }

    func release(_ child: Process) {
        lock.lock()
        defer { lock.unlock() }
        if process === child { process = nil }
    }
}

/// The PATH a Terminal window would have: the person's login shell, run
/// once with its startup files, asked only when they look again for a
/// Codex that was not found.
enum AgentLoginShell {
    private static let timeout: TimeInterval = 5
    private static let marker = "__MACTOOLS_AI_USAGE_PATH__"

    static var currentShellPath: String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    static func path(shellPath: String = currentShellPath) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-c", "printf '%s%s' '\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while the shell runs, so a chatty startup file cannot fill the pipe.
        let read = LoginShellOutput()
        let reader = DispatchQueue(label: "mactools.ai-usage.login-shell")
        reader.async { read.data = output.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            return nil
        }
        reader.sync {}
        guard process.terminationStatus == 0,
              let text = String(data: read.data, encoding: .utf8),
              let range = text.range(of: marker, options: .backwards) else { return nil }
        let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// What the login shell printed, filled on its reader queue and read after `reader.sync {}`.
private final class LoginShellOutput: @unchecked Sendable {
    var data = Data()
}
