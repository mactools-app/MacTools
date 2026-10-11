import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacTools

@MainActor
final class MenuBarIconPreparationTests: XCTestCase {
    func testRestoredAnimationBecomesReadyWithoutChangingSavedSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let stored = fixture.defaults.data(forKey: "menubar.icon.settings")
        let settings = MenuBarIconSettings(userDefaults: fixture.defaults, rootDirectory: fixture.directory)
        let ready = expectation(description: "Animation prepared")
        let observation = settings.$settingsRevision.dropFirst().sink { _ in ready.fulfill() }

        XCTAssertFalse(settings.imagePayload().isAnimated)
        await fulfillment(of: [ready], timeout: 5)
        let payload = settings.imagePayload()
        XCTAssertTrue(payload.isAnimated)
        XCTAssertEqual(payload.animationFrames.count, 2)
        XCTAssertTrue(payload.isTemplate)
        XCTAssertEqual(fixture.defaults.data(forKey: "menubar.icon.settings"), stored)
        withExtendedLifetime(observation) {}
    }

    func testRestoreDefaultsCannotBeOverriddenByPendingAnimationPreparation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = MenuBarIconSettings(userDefaults: fixture.defaults, rootDirectory: fixture.directory)
        _ = settings.imagePayload()
        settings.resetToDefault()
        let expected = settings.imagePayload()
        await settings.waitForFramePreparationForTests()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.imagePayload(), expected)
    }

    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let suite = "MenuBarIconPreparationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let framesDirectory = directory.appendingPathComponent("MenuBarIcons/Recents")
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        let names = ["frame-0.png", "frame-1.png"]
        for (index, name) in names.enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 3 + index, y: 3, width: 8, height: 8))
            let image = try XCTUnwrap(context.makeImage())
            let url = framesDirectory.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let selection = MenuBarIconLocalSelection(fileName: names[0], frameFileNames: names, frameDuration: 0.2)
        struct State: Encodable { let localIconSelection: MenuBarIconLocalSelection }
        defaults.set(try JSONEncoder().encode(State(localIconSelection: selection)), forKey: "menubar.icon.settings")
        return Fixture(directory: directory, defaults: defaults, suite: suite)
    }
}
