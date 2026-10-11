import CoreVideo
import Foundation
import MacToolsPluginKit

/// Lifecycle methods run on the smoother's serial queue. The output callback
/// only schedules work there, so stopping never waits for work on that queue.
protocol MouseScrollFrameDriving: AnyObject {
    func start(frame: @escaping @Sendable () -> Void) -> Bool
    func stop()
    func invalidate()
}

final class MouseScrollFrameDriver: MouseScrollFrameDriving, @unchecked Sendable {
    private let callbackLock = NSLock()
    private var frameHandler: (@Sendable () -> Void)?
    private var displayLink: CVDisplayLink?
    private var callbackPointer: UnsafeMutableRawPointer?

    deinit { invalidate() }

    func start(frame: @escaping @Sendable () -> Void) -> Bool {
        callbackLock.withLock { frameHandler = frame }
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
                invalidate()
                return false
            }

            let context = PluginCallbackContext(owner: self)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            let result = CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnSuccess }
                let context = Unmanaged<PluginCallbackContext<MouseScrollFrameDriver>>
                    .fromOpaque(userInfo).takeUnretainedValue()
                context.withOwner { driver in
                    let handler = driver.callbackLock.withLock { driver.frameHandler }
                    handler?()
                }
                return kCVReturnSuccess
            }, pointer)
            guard result == kCVReturnSuccess else {
                context.invalidate()
                Unmanaged<PluginCallbackContext<MouseScrollFrameDriver>>.fromOpaque(pointer).release()
                invalidate()
                return false
            }
            displayLink = link
            callbackPointer = pointer
        }

        guard let displayLink else { return false }
        if CVDisplayLinkIsRunning(displayLink) { return true }
        guard CVDisplayLinkStart(displayLink) == kCVReturnSuccess else {
            invalidate()
            return false
        }
        return true
    }

    func stop() {
        callbackLock.withLock { frameHandler = nil }
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    func invalidate() {
        if let callbackPointer {
            Unmanaged<PluginCallbackContext<MouseScrollFrameDriver>>.fromOpaque(callbackPointer)
                .takeUnretainedValue().invalidate()
        }
        stop()
        displayLink = nil
        if let callbackPointer {
            Unmanaged<PluginCallbackContext<MouseScrollFrameDriver>>.fromOpaque(callbackPointer).release()
        }
        callbackPointer = nil
    }
}
