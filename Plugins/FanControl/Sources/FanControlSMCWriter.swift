import Foundation
import MacToolsPluginKit

// MARK: - FanControlSMCWriter

/// Writes SMC fan control values through MacTools' bundled SMC helper.
/// The helper is copied to `/Library/PrivilegedHelperTools` with root ownership
/// and setuid permissions on first use. The helper itself rejects unprivileged
/// writes and verifies that the SMC value changed before reporting success.
@MainActor
final class FanControlSMCWriter: FanControlSMCWriting {
    private enum Helper {
        static let bundledName = "mactools-fan-smc-helper"
        static let bundledSubdirectory = "SMCHelper"
        static let installPath = "/Library/PrivilegedHelperTools/cc.ggbond.mactools.fan-control.smc-helper"
        static let installDirectory = "/Library/PrivilegedHelperTools"
    }

    private let fileManager: FileManager
    private let resourceBundle: Bundle
    private let localization: PluginLocalization
    let helperInstallPath: String

    private var resolvedHelperPath: String?

    init(
        resourceBundle: Bundle = .main,
        fileManager: FileManager = .default,
        localization: PluginLocalization? = nil,
        releaseChannel: String? = Bundle.main.object(forInfoDictionaryKey: "MTReleaseChannel") as? String
    ) {
        self.resourceBundle = resourceBundle
        self.fileManager = fileManager
        self.localization = localization ?? PluginLocalization(bundle: resourceBundle)
        self.helperInstallPath = Helper.installPath + (releaseChannel == "nightly" ? ".nightly" : "")
    }

    // MARK: - Public API

    typealias WriteError = FanWriteError

    var isHelperAvailable: Bool {
        bundledHelperURL != nil
    }

    var isInstalledHelperAvailable: Bool {
        guard let bundledHelperURL else {
            return false
        }

        return installedHelperPath(matching: bundledHelperURL) != nil
    }

    /// Apply `strategy` to all fans described by `snapshot`.
    /// - Returns: `nil` on success, or an error description on failure.
    @discardableResult
    func apply(strategy: FanControlStrategy, snapshot: FanSnapshot) -> FanWriteError? {
        let resolvedPath: String
        switch helperPath() {
        case .success(let path):
            resolvedPath = path
        case .failure(let error):
            FanControlLog.writer.error("smc-helper not found")
            return error
        }

        let fanCount = max(1, snapshot.fanCount)

        switch strategy {
        case .auto:
            var allOK = true
            for i in 0..<fanCount {
                if !runHelper(path: resolvedPath, args: ["auto", "\(i)"]) { allOK = false }
            }
            if !allOK {
                return .writeFailed(.restoreAutoPartial)
            }

        case .fullSpeed:
            var allOK = true
            for i in 0..<fanCount {
                let maxRPM = i < snapshot.fanMaxSpeeds.count
                    ? snapshot.fanMaxSpeeds[i]
                    : FanRPMLimits.fallbackMax
                let safe = max(FanRPMLimits.absoluteMin, min(FanRPMLimits.absoluteMax, maxRPM))
                if !runHelper(path: resolvedPath, args: ["set", "\(i)", "\(safe)"]) { allOK = false }
            }
            if !allOK {
                return .writeFailed(.fullSpeedPartial)
            }

        case .fixed(let rpm):
            let safe = max(FanRPMLimits.absoluteMin, min(FanRPMLimits.absoluteMax, rpm))
            var allOK = true
            for i in 0..<fanCount {
                let perFanMax = i < snapshot.fanMaxSpeeds.count
                    ? snapshot.fanMaxSpeeds[i]
                    : FanRPMLimits.fallbackMax
                let perFanMin = i < snapshot.fanMinSpeeds.count
                    ? snapshot.fanMinSpeeds[i]
                    : FanRPMLimits.fallbackMin
                let clamped = max(perFanMin, min(perFanMax, safe))
                if !runHelper(path: resolvedPath, args: ["set", "\(i)", "\(clamped)"]) { allOK = false }
            }
            if !allOK {
                return .writeFailed(.fixedRPMPartial)
            }
        }

        return nil
    }

    // MARK: - Private

    private func installedHelperPath(matching bundledHelperURL: URL) -> String? {
        if let cached = resolvedHelperPath,
           isExecutable(at: cached),
           installedHelperMatchesBundled(installedPath: cached, bundledURL: bundledHelperURL) {
            return cached
        }

        guard isExecutable(at: helperInstallPath),
              installedHelperMatchesBundled(installedPath: helperInstallPath, bundledURL: bundledHelperURL)
        else {
            return nil
        }

        resolvedHelperPath = helperInstallPath
        return helperInstallPath
    }

    private var bundledHelperURL: URL? {
        resourceBundle.url(
            forResource: Helper.bundledName,
            withExtension: nil,
            subdirectory: Helper.bundledSubdirectory
        )
    }

    private func helperPath() -> Result<String, FanWriteError> {
        guard let bundledHelperURL else {
            return .failure(.helperNotFound)
        }

        guard verifyBundleContainingBundledHelper(bundledHelperURL) else {
            return .failure(.helperVerificationFailed)
        }

        if let installedHelperPath = installedHelperPath(matching: bundledHelperURL) {
            return .success(installedHelperPath)
        }

        if let error = installBundledHelper(from: bundledHelperURL) {
            return .failure(error)
        }

        guard let installedHelperPath = installedHelperPath(matching: bundledHelperURL) else {
            return .failure(.helperInstallFailed(.missingAfterInstall))
        }

        return .success(installedHelperPath)
    }

    private func isExecutable(at path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    private func installedHelperMatchesBundled(installedPath: String, bundledURL: URL) -> Bool {
        guard let installedAttributes = try? fileManager.attributesOfItem(atPath: installedPath),
              Self.helperHasExpectedPrivileges(attributes: installedAttributes),
              let installedSize = installedAttributes[.size] as? NSNumber,
              let installedModifiedAt = installedAttributes[.modificationDate] as? Date,
              let bundledAttributes = try? fileManager.attributesOfItem(atPath: bundledURL.path),
              let bundledSize = bundledAttributes[.size] as? NSNumber,
              let bundledModifiedAt = bundledAttributes[.modificationDate] as? Date,
              let installedData = try? Data(contentsOf: URL(fileURLWithPath: installedPath)),
              let bundledData = try? Data(contentsOf: bundledURL)
        else {
            return false
        }

        guard installedSize == bundledSize else {
            return false
        }

        return installedModifiedAt.timeIntervalSince(bundledModifiedAt) >= -1
            && installedData == bundledData
    }

    static func helperHasExpectedPrivileges(attributes: [FileAttributeKey: Any]) -> Bool {
        guard let ownerID = attributes[.ownerAccountID] as? NSNumber,
              let groupID = attributes[.groupOwnerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber
        else {
            return false
        }

        return ownerID.intValue == 0
            && groupID.intValue == 0
            && permissions.intValue & 0o7777 == 0o4755
    }

    private func verifyBundleContainingBundledHelper(_ helperURL: URL) -> Bool {
        var currentURL = helperURL.deletingLastPathComponent()

        while currentURL.path != "/" {
            if currentURL.pathExtension == "bundle" {
                return verifyCodeSignature(at: currentURL)
            }
            currentURL.deleteLastPathComponent()
        }

        return false
    }

    private func verifyCodeSignature(at url: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--strict", "--deep", url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            FanControlLog.writer.error("codesign verification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func installBundledHelper(from sourceURL: URL) -> FanWriteError? {
        guard isExecutable(at: sourceURL.path) else {
            return .helperNotFound
        }

        let command = [
            "/bin/mkdir -p \(shellQuoted(Helper.installDirectory))",
            "/usr/bin/install -o root -g wheel -m 4755 \(shellQuoted(sourceURL.path)) \(shellQuoted(helperInstallPath))",
            "/usr/bin/touch -r \(shellQuoted(sourceURL.path)) \(shellQuoted(helperInstallPath))",
            "/bin/chmod 4755 \(shellQuoted(helperInstallPath))"
        ].joined(separator: " && ")

        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        var appleScriptError: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return .helperInstallFailed(.authorizationScriptUnavailable)
        }

        _ = scriptObject.executeAndReturnError(&appleScriptError)
        if let appleScriptError {
            let message = appleScriptError["NSAppleScriptErrorMessage"] as? String
                ?? appleScriptError.description
            FanControlLog.writer.error("SMC helper install failed: \(message, privacy: .public)")
            return .helperInstallFailed(.systemMessage(message))
        }

        resolvedHelperPath = nil
        return nil
    }

    @discardableResult
    private func runHelper(path: String, args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = ["LANG": "C"]
        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return true
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            FanControlLog.writer.error(
                "smc-helper failed with status \(task.terminationStatus): \(errorMessage ?? "unknown", privacy: .public)"
            )
        } catch {
            FanControlLog.writer.error("smc-helper launch failed: \(error.localizedDescription, privacy: .public)")
        }

        return false
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
