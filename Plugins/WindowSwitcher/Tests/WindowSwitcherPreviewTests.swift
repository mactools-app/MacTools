import AppKit
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherPreviewTests: XCTestCase {
    func testLanguageChangeRetainsCapturedPreviewAndReprojectsFailureWithoutRecapturing() async throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let resources = try makeLocalizationBundle()
        defer { try? FileManager.default.removeItem(at: resources.directory) }
        PluginRuntimeLocalization.source.setPreference("en")

        let image = NSImage(size: NSSize(width: 3, height: 3))
        var captures = 0
        var publications = 0
        let preview = WindowSwitcherPreview(
            localization: PluginLocalization(bundle: resources.bundle),
            hasPermission: { true }, debounceDelay: .zero,
            capture: { _ in captures += 1; return image }
        )
        preview.onChange = { _, _ in publications += 1 }
        let entry = makeEntry(number: 7)
        preview.select(entry)
        try await waitUntil { preview.currentImage === image }
        let publicationsAfterCapture = publications

        PluginRuntimeLocalization.source.setPreference("ar")
        preview.select(entry)
        XCTAssertTrue(preview.currentImage === image)
        XCTAssertNil(preview.status)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(publications, publicationsAfterCapture)

        preview.select(nil)
        let failureMessage = try XCTUnwrap(preview.statusMessage)
        let publicationsAfterFailure = publications
        PluginRuntimeLocalization.source.setPreference("en")

        XCTAssertEqual(preview.status, .unavailable)
        XCTAssertNotEqual(preview.statusMessage, failureMessage)
        XCTAssertNil(preview.currentImage)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(publications, publicationsAfterFailure)
    }

    func testPreviewKeepsGestureResponderWhileNextScreenshotLoads() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let stage = WindowSwitcherPreviewStage(frame: panel.contentView!.bounds)
        panel.contentView = stage
        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        XCTAssertTrue(panel.makeFirstResponder(stage))

        stage.retireImage()
        XCTAssertTrue(stage.acceptsFirstResponder)
        XCTAssertTrue(panel.firstResponder === stage)
    }

    func testPinchDuringPreviewCaptureZoomsTheSelectedImageWhenItArrives() {
        let stage = WindowSwitcherPreviewStage(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        stage.retireImage()
        let anchor = CGPoint(x: 250, y: 150)
        stage.consumeMagnification(change: 0, state: .began, anchor: anchor)
        stage.consumeMagnification(change: 0.4, state: .changed, anchor: anchor)
        stage.consumeMagnification(change: 0, state: .ended, anchor: anchor)
        XCTAssertEqual(stage.zoomScale, 1)

        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        XCTAssertEqual(stage.zoomScale, 1.4, accuracy: 0.001)
    }

    func testActivePinchFollowsTabSelectionAndWaitsForNextPreview() {
        let stage = WindowSwitcherPreviewStage(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let anchor = CGPoint(x: 250, y: 150)
        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        stage.consumeMagnification(change: 0, state: .began, anchor: anchor)
        stage.consumeMagnification(change: 0.4, state: .changed, anchor: anchor)
        XCTAssertEqual(stage.zoomScale, 1.4, accuracy: 0.001)

        stage.retireImage()
        stage.consumeMagnification(change: 0.2, state: .changed, anchor: anchor)
        XCTAssertEqual(stage.zoomScale, 1)
        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        XCTAssertEqual(stage.zoomScale, 1.2, accuracy: 0.001)
    }

    func testCompletedPinchDoesNotCarryAcrossTabSelection() {
        let stage = WindowSwitcherPreviewStage(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let anchor = CGPoint(x: 250, y: 150)
        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        stage.consumeMagnification(change: 0, state: .began, anchor: anchor)
        stage.consumeMagnification(change: 0.4, state: .changed, anchor: anchor)
        stage.consumeMagnification(change: 0, state: .ended, anchor: anchor)
        stage.retireImage()
        stage.consumeMagnification(change: 0.4, state: .changed, anchor: anchor)
        stage.image = NSImage(size: NSSize(width: 800, height: 500))
        XCTAssertEqual(stage.zoomScale, 1)
    }

    func testExactCaptureWindowIDWins() {
        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99]
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: .zero, title: nil, layer: 0, windowID: 7),
            WindowSwitcherPreviewCandidate(processID: 42, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates), 0)
    }

    func testExactCaptureWindowIDRejectsUnrelatedProcess() {
        let entry = makeEntry(number: 7)
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 7),
        ]
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates))
    }

    func testCaptureFallsBackToUniqueOwnerGeometryWhenCompositorIDDiffers() {
        var entry = makeEntry(number: 7)
        entry.windowOwnerPID = 43
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 43, frame: entry.bounds, title: "Different capture title", layer: 0, windowID: 8),
            WindowSwitcherPreviewCandidate(processID: 43, frame: CGRect(x: 900, y: 20, width: 800, height: 600),
                                           title: "Other", layer: 0, windowID: 9),
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates), 0)
    }

    func testCaptureFallsBackToUniqueTitleForVerifiedHelperOwnedSurface() {
        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99, 100]
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
            WindowSwitcherPreviewCandidate(processID: 100, frame: entry.bounds, title: "Overlay", layer: 0, windowID: 9),
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates), 0)
    }

    func testCaptureRejectsUnrelatedProcessWithSameTitleAndGeometry() {
        let entry = makeEntry(number: 7)
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
        ]
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates))
    }

    func testCaptureRejectsAmbiguousHelperSurfaces() {
        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99, 100]
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
            WindowSwitcherPreviewCandidate(processID: 100, frame: entry.bounds, title: "Steam", layer: 0, windowID: 9),
        ]
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates))
    }

    func testHelperAuthorizationChangeRejectsStaleCaptureAndRecapturesSelection() async throws {
        var capturedEntries: [WindowSwitcherAppEntry] = []
        var continuations: [CheckedContinuation<NSImage?, Never>] = []
        let preview = WindowSwitcherPreview(hasPermission: { true }, captureTimeout: .seconds(1),
            debounceDelay: .zero, capture: { entry in
                capturedEntries.append(entry)
                return await withCheckedContinuation { continuations.append($0) }
            })
        var receivedImages: [NSImage] = []
        preview.onChange = { image, _ in
            if let image { receivedImages.append(image) }
        }

        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99]
        preview.select(entry)
        try await waitUntil { continuations.count == 1 }

        entry.previewProcessIdentifiers = [100]
        preview.select(entry)
        let stale = NSImage(size: NSSize(width: 2, height: 2))
        continuations.removeFirst().resume(returning: stale)
        try await waitUntil { capturedEntries.count == 2 && continuations.count == 1 }

        let current = NSImage(size: NSSize(width: 3, height: 3))
        continuations.removeFirst().resume(returning: current)
        try await waitUntil { receivedImages.count == 1 }

        XCTAssertEqual(capturedEntries.map(\.previewProcessIdentifiers), [[99], [100]])
        XCTAssertTrue(receivedImages[0] === current)
        XCTAssertFalse(receivedImages.contains { $0 === stale })
    }

    private func makeEntry(number: CGWindowID) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: "steam", processIdentifier: 42,
            bundleIdentifier: "com.valvesoftware.steam", appName: "Steam", windowTitle: "Steam",
            icon: nil, windowElement: AXUIElementCreateApplication(42), isMinimized: false,
            windowNumber: number, shortcutToken: nil,
            bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
    }

    private func makeLocalizationBundle() throws -> (bundle: Bundle, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("WindowSwitcherPreviewTests.bundle", isDirectory: true)
        for language in ["en", "ar"] {
            let languageURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
            try "\"preview.unavailable\" = \"preview-unavailable-\(language)\";".write(
                to: languageURL.appendingPathComponent("Localizable.strings"),
                atomically: true, encoding: .utf8
            )
        }
        return (try XCTUnwrap(Bundle(url: bundleURL)), directory)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for preview state")
    }
}
