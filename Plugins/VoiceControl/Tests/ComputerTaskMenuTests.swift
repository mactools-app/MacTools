import ApplicationServices
import Foundation
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class ComputerTaskMenuTests: XCTestCase {
    func testMenuResolutionHonorsStopAndDeadlineBetweenAttributeReads() async throws {
        for mode in ["normal", "stop", "deadline", "walk-deadline"] {
            let fixture = MenuReadFixture()
            let native = ComputerTaskNativeInput(copyAttribute: { fixture.read($0, $1, $2) },
                setMessagingTimeout: { _, _ in .success }, now: { fixture.date })
            defer { native.stop() }
            if mode != "normal" {
                fixture.arm {
                    fixture.interrupt(expired: mode != "stop")
                    if mode == "stop" { native.stop() }
                }
            }
            let target = ComputerUseTarget(pid: getpid(), windowID: 0, name: "Owned menu fixture",
                launched: try XCTUnwrap(ComputerTaskNativeInput.launchDate(getpid())))
            do {
                let result = try await native.menus(target, path: mode == "walk-deadline" ? ["File"] : ["File", "Entry"])
                XCTAssertTrue(["normal", "walk-deadline"].contains(mode), "Interrupted resolution must not return a usable observation")
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
                XCTAssertEqual(value["complete"] as? Bool, mode == "normal")
            } catch is CancellationError {
                XCTAssertEqual(mode, "stop")
            } catch {
                XCTAssertEqual(mode, "deadline")
                guard let failure = error as? ComputerUseError, case .unavailable = failure else { throw error }
            }
            XCTAssertEqual(fixture.readsAfterInterruption, 0, "Do not issue another AX read after Stop or expiry")
        }
    }
}

private final class MenuReadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let app = AXUIElementCreateApplication(getpid())
    private let bar = AXUIElementCreateApplication(100_001)
    private let file = AXUIElementCreateApplication(100_002)
    private let menu = AXUIElementCreateApplication(100_003)
    private let entries = (100_100..<100_106).map { AXUIElementCreateApplication(Int32($0)) }
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var interrupted = false
    private var after = 0
    private var onEntry: (@Sendable () -> Void)?
    var date: Date { lock.withLock { clock } }
    var readsAfterInterruption: Int { lock.withLock { after } }
    func arm(_ action: @escaping @Sendable () -> Void) { lock.withLock { onEntry = action } }
    func interrupt(expired: Bool) {
        lock.withLock { interrupted = true; if expired { clock = clock.addingTimeInterval(3) } }
    }
    func read(_ element: AXUIElement, _ attribute: CFString, _ raw: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
        let name = attribute as String
        let entry = entries.firstIndex { CFEqual($0, element) }
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            if interrupted { after += 1 }
            guard name == kAXRoleAttribute, entry != nil else { return nil }
            let action = onEntry; onEntry = nil; return action
        }
        action?()
        if name == kAXMenuBarAttribute, CFEqual(element, app) { raw.pointee = bar; return .success }
        if name == kAXChildrenAttribute {
            if CFEqual(element, bar) { raw.pointee = [file] as CFArray }
            else if CFEqual(element, file) { raw.pointee = [menu] as CFArray }
            else if CFEqual(element, menu) { raw.pointee = entries as CFArray }
            else { raw.pointee = [] as CFArray }
            return .success
        }
        if name == kAXRoleAttribute {
            raw.pointee = (CFEqual(element, menu) ? kAXMenuRole : kAXMenuItemRole) as CFString
            return .success
        }
        if name == kAXTitleAttribute {
            raw.pointee = (CFEqual(element, file) ? "File" : entry == 0 ? "Entry" : "Other") as CFString
            return .success
        }
        return .attributeUnsupported
    }
}
