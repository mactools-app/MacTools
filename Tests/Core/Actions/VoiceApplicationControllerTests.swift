import Foundation
import XCTest
@testable import MacTools

final class VoiceApplicationControllerTests: XCTestCase {
    func testApplicationTargetsRequireAnExecutableTopLevelBundleAndKeepFileIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let executable = app.appendingPathComponent("Contents/MacOS/fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.voice.fixture", "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(SystemVoiceApplicationController.target(at: app))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let target = try XCTUnwrap(SystemVoiceApplicationController.target(at: app))
        XCTAssertEqual(target.bundleIdentifier, "test.voice.fixture")
        XCTAssertNotNil(target.fileIdentity)
        let nested = root.appendingPathComponent("Container.app/Contents/Fixture.app")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: nested)
        XCTAssertNil(SystemVoiceApplicationController.target(at: nested))
        try FileManager.default.removeItem(at: app)
        XCTAssertNil(SystemVoiceApplicationController.target(at: app))
    }
}
