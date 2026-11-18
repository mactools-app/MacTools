import Foundation

struct BitwardenCLI: Sendable {
    enum Failure: Error { case unavailable, invalidResponse, commandFailed, tooLarge }

    let directory: URL
    private let executablePaths: [String]

    init(directory: URL, executablePaths: [String] = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]) {
        self.directory = directory
        self.executablePaths = executablePaths
    }

    var executable: URL? {
        executablePaths
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    func run(
        _ arguments: [String], session: String? = nil, input: Data? = nil,
        password: String? = nil
    ) async throws -> Data {
        guard let executable else { throw Failure.unavailable }
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("BW_") || key.hasPrefix("NODE_") {
                environment.removeValue(forKey: key)
            }
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            environment["BITWARDENCLI_APPDATA_DIR"] = directory.path
            environment["BW_NOINTERACTION"] = "true"
            environment["BW_SESSION"] = session
            environment["MACTOOLS_BW_PASSWORD"] = password
            process.environment = environment
            let output = Pipe()
            let stdin = input.map { _ in Pipe() }
            process.standardInput = stdin ?? FileHandle.nullDevice as Any
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            if let stdin, let input {
                // The CLI reads its request after initialization. Drain its output in parallel.
                DispatchQueue.global(qos: .userInitiated).async {
                    let writer = stdin.fileHandleForWriting
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
            }
            let timeout = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            defer { timeout.cancel() }
            var result = Data()
            let reader = output.fileHandleForReading
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard result.count + chunk.count <= 64 * 1024 * 1024 else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    throw Failure.tooLarge
                }
                result.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.commandFailed }
            return result
        }.value
    }
}
