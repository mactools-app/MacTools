import Darwin
import Foundation
@main
struct Runner {
    @MainActor static func main() async throws {
        let library = URL(fileURLWithPath: CommandLine.arguments[1])
        let image = dlopen(library.path, RTLD_NOW | RTLD_LOCAL)!
        let entered = unsafeBitCast(dlsym(image, "test_create_entered"), to: (@convention(c) () -> Int32).self)
        let allow = unsafeBitCast(dlsym(image, "test_allow_create"), to: (@convention(c) () -> Void).self)
        let count = unsafeBitCast(dlsym(image, "test_invokes"), to: (@convention(c) () -> Int32).self)
        let runtime = CuaRuntime(libraryURL: library)
        let task = Task.detached { try await runtime.invoke("get_window_state", arguments: Data("{}".utf8)) }
        for _ in 0..<10_000 {
            if entered() != 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard entered() != 0 else { print("SDK fixture did not enter create"); exit(1) }
        task.cancel()
        allow()
        var cancelled = false
        do { _ = try await task.value; print("result: success") }
        catch is CancellationError { cancelled = true; print("result: CancellationError") }
        catch { print("result: \(error)") }
        print("native invocations after cancellation: \(count())")
        await runtime.shutdown()
        guard cancelled, count() == 0 else { exit(1) }
    }
}
