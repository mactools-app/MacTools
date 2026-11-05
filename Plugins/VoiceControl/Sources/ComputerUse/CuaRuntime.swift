import CuaDriverABI
import Darwin
import Foundation

protocol CuaRuntimeCalling: Sendable {
    func invoke(_ tool: String, arguments: Data) async throws -> Data
    func shutdown() async
}

/// Only these SDK tools can cross the plugin boundary. Scripts, installers,
/// daemons, global input, browser-profile attachment and recording are excluded.
actor CuaRuntime: CuaRuntimeCalling {
    static let allowedTools: Set<String> = ["get_window_state", "set_value", "click", "scroll"]
    private let libraryURL: URL
    private var symbols: CuaSymbols?
    private var driver: OpaquePointer?
    private var requests: [UUID: CuaRequest] = [:]
    private var closing = false

    init(libraryURL: URL) { self.libraryURL = libraryURL }

    func invoke(_ tool: String, arguments: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !closing, requests.isEmpty, Self.allowedTools.contains(tool), arguments.count <= 16_384 else {
            throw ComputerUseError.unavailable("Computer Use is stopped or the operation is unsupported.")
        }
        let symbols = try load()
        try Task.checkCancellation()
        let request = CuaRequest(symbols: symbols)
        let id = UUID()
        requests[id] = request
        defer { requests[id] = nil }
        do { return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.register(continuation) else { return }
                let context = Unmanaged.passRetained(request).toOpaque()
                var operation: OpaquePointer?
                var error = CuaDriverBuffer()
                let status = Array(tool.utf8).withUnsafeBufferPointer { name in
                    arguments.withUnsafeBytes { args in
                        symbols.invoke(driver, name.baseAddress, name.count,
                            args.bindMemory(to: UInt8.self).baseAddress, args.count,
                            cuaCompletion, context, &operation, &error)
                    }
                }
                if status == 0 {
                    request.install(operation)
                } else {
                    Unmanaged<CuaRequest>.fromOpaque(context).release()
                    request.complete(.failure(ComputerUseError.unavailable(symbols.consume(&error))))
                }
                symbols.free(&error)
            }
        } onCancel: { request.cancel() }
        } catch is CancellationError {
            requests[id] = nil
            await shutdown()
            throw CancellationError()
        }
    }

    func shutdown() async {
        guard !closing else { return }
        closing = true
        requests.values.forEach { $0.cancel() }
        guard let symbols, driver != nil else { closing = false; return }
        let request = CuaRequest(symbols: symbols)
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            guard request.register(continuation) else { return }
            let context = Unmanaged.passRetained(request).toOpaque()
            var operation: OpaquePointer?
            var error = CuaDriverBuffer()
            let status = symbols.shutdown(driver, cuaCompletion, context, &operation, &error)
            if status == 0 { request.install(operation) }
            else {
                Unmanaged<CuaRequest>.fromOpaque(context).release()
                request.complete(.failure(ComputerUseError.unavailable(symbols.consume(&error))))
            }
            symbols.free(&error)
        }
        symbols.destroy(&driver)
        closing = false
    }

    private func load() throws -> CuaSymbols {
        if symbols == nil { symbols = try CuaSymbols(url: libraryURL) }
        let symbols = symbols!
        if driver == nil {
            // Do not inherit an unrestricted authorization mode from the environment.
            let options = Data(#"{"authorization":{"allowed_modes":["standard"],"compatibility_mode":"standard","unrestricted_acknowledged":false,"max_session_ttl_seconds":600,"max_idle_ttl_seconds":120}}"#.utf8)
            var error = CuaDriverBuffer()
            var handle: OpaquePointer?
            let status = options.withUnsafeBytes {
                symbols.create($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &handle, &error)
            }
            defer { symbols.free(&error) }
            guard status == 0, handle != nil else {
                throw ComputerUseError.unavailable(symbols.consume(&error))
            }
            driver = handle
        }
        return symbols
    }
}

/// The image stays loaded until host exit. Cua installs process-level callbacks;
/// shutting down its runtime does not make unloading that native code safe.
private final class CuaSymbols: @unchecked Sendable {
    typealias Create = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    typealias Destroy = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    typealias Invoke = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, CuaDriverCompletionV1?, UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    typealias Shutdown = @convention(c) (OpaquePointer?, CuaDriverCompletionV1?, UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    typealias Free = @convention(c) (UnsafeMutablePointer<CuaDriverBuffer>?) -> Void
    typealias Cancel = @convention(c) (OpaquePointer?) -> Void
    typealias Release = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    typealias Compatible = @convention(c) (UInt16, UInt16) -> Bool
    let create: Create
    let destroy: Destroy
    let invoke: Invoke
    let shutdown: Shutdown
    let free: Free
    let cancel: Cancel
    let release: Release

    init(url: URL) throws {
        guard let image = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw ComputerUseError.unavailable("The bundled Cua SDK could not be loaded. Reinstall Computer Use.")
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(image, name) else {
                throw ComputerUseError.unavailable("The bundled Cua SDK is incompatible.")
            }
            return unsafeBitCast(address, to: type)
        }
        let compatible = try symbol("cua_driver_abi_is_compatible_v1", as: Compatible.self)
        guard compatible(1, 1) else { throw ComputerUseError.unavailable("Cua ABI 1.1 is required.") }
        let policy = try symbol("cua_driver_mactools_policy_v1", as: (@convention(c) () -> UInt32).self)
        guard policy() == 3 else { throw ComputerUseError.unavailable("The current native-only Cua policy is required. Update Voice Assistant.") }
        create = try symbol("cua_driver_create_v1", as: Create.self)
        destroy = try symbol("cua_driver_destroy_v1", as: Destroy.self)
        invoke = try symbol("cua_driver_invoke_v1", as: Invoke.self)
        shutdown = try symbol("cua_driver_shutdown_v1", as: Shutdown.self)
        free = try symbol("cua_driver_buffer_free_v1", as: Free.self)
        cancel = try symbol("cua_driver_operation_cancel_v1", as: Cancel.self)
        release = try symbol("cua_driver_operation_release_v1", as: Release.self)
    }

    func consume(_ buffer: inout CuaDriverBuffer) -> String {
        guard buffer.len <= 262_144, let pointer = buffer.data else { return "Cua returned an unavailable or oversized result." }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: buffer.len), as: UTF8.self)
    }
}

/// Cancellation can arrive before the SDK publishes its operation token, and
/// completion can arrive before invoke returns. This lock owns both races.
private final class CuaRequest: @unchecked Sendable {
    let symbols: CuaSymbols
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()
    private var operation: OpaquePointer?
    private var cancelled = false
    private var finished = false

    init(symbols: CuaSymbols) { self.symbols = symbols }

    /// This lock is the admission boundary. Already-cancelled requests never enter Cua.
    func register(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        guard !cancelled, !finished else {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(_ token: OpaquePointer?) {
        lock.lock()
        operation = token
        if cancelled { symbols.cancel(operation) }
        if finished { symbols.release(&operation) }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let operation { symbols.cancel(operation) }
        lock.unlock()
    }

    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        symbols.release(&operation)
        let result: Result<Data, Error> = cancelled ? .failure(CancellationError()) : result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func cuaCompletion(_ context: UnsafeMutableRawPointer?, _ status: Int32,
                           _ result: CuaDriverBuffer, _ error: CuaDriverBuffer) {
    guard let context else { return }
    let request = Unmanaged<CuaRequest>.fromOpaque(context).takeRetainedValue()
    var result = result
    var error = error
    defer { request.symbols.free(&result); request.symbols.free(&error) }
    if status == 0, result.len <= 262_144, let pointer = result.data {
        request.complete(.success(Data(bytes: pointer, count: result.len)))
    } else if status == 5 {
        request.complete(.failure(CancellationError()))
    } else {
        request.complete(.failure(ComputerUseError.unavailable(request.symbols.consume(&error))))
    }
}
