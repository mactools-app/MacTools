import Foundation

/// Own AX resources on one run loop. No caller waits for a remote app or joins
/// this thread; queued foreground changes take precedence over accessory setup.
final class AutoInputAccessibilityRunLoop: @unchecked Sendable {
    enum Priority { case foreground, background }
    private let state = State()

    func perform(priority: Priority = .background, _ work: @escaping @Sendable () -> Void) {
        state.enqueue(priority: priority, work: work)
    }

    func shutdown(_ cleanup: @escaping @Sendable () -> Void = {}) {
        state.shutdown(cleanup)
    }

    deinit { state.shutdown({}) }

    // Only scheduling state crosses threads. AX callbacks and all submitted
    // operations execute on the dedicated thread, including resource teardown.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var foreground: [@Sendable () -> Void] = []
        private var background: [@Sendable () -> Void] = []
        private var runLoop: CFRunLoop?
        private var started = false
        private var scheduled = false
        private var stopping = false

        func enqueue(priority: Priority, work: @escaping @Sendable () -> Void) {
            lock.lock()
            guard !stopping else { lock.unlock(); return }
            if priority == .foreground { foreground.append(work) }
            else { background.append(work) }
            let shouldStart = !started
            started = true
            lock.unlock()
            if shouldStart { startThread() }
            schedule()
        }

        func shutdown(_ cleanup: @escaping @Sendable () -> Void) {
            lock.lock()
            guard !stopping else { lock.unlock(); return }
            stopping = true
            foreground.removeAll()
            background.removeAll()
            guard started else { lock.unlock(); return }
            foreground.append {
                cleanup()
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            lock.unlock()
            schedule()
        }

        private func startThread() {
            let thread = Thread { [self] in
                autoreleasepool {
                    let loop = CFRunLoopGetCurrent()!
                    var context = CFRunLoopSourceContext()
                    // A live source keeps the loop asleep between jobs and AX events.
                    context.perform = { _ in }
                    let source = CFRunLoopSourceCreate(nil, 0, &context)!
                    CFRunLoopAddSource(loop, source, .defaultMode)
                    lock.withLock { runLoop = loop }
                    schedule()
                    CFRunLoopRun()
                    CFRunLoopRemoveSource(loop, source, .defaultMode)
                    lock.withLock { runLoop = nil }
                }
            }
            thread.name = "MacTools Auto Input Accessibility"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        private func schedule() {
            lock.lock()
            guard let loop = runLoop, !scheduled,
                  !foreground.isEmpty || !background.isEmpty else { lock.unlock(); return }
            scheduled = true
            lock.unlock()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                let work: (@Sendable () -> Void)? = lock.withLock {
                    scheduled = false
                    if !foreground.isEmpty { return foreground.removeFirst() }
                    if !background.isEmpty { return background.removeFirst() }
                    return nil
                }
                autoreleasepool { work?() }
                schedule()
            }
            CFRunLoopWakeUp(loop)
        }
    }
}
