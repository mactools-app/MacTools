import Foundation
import SQLite3
import XCTest
@testable import AIUsagePlugin

/// A stop while OpenCode holds its database locked must not wait out SQLite's
/// busy timeout: the host waits on the reader when it saves progress or quits.
final class AIUsageOpenCodeLockTests: XCTestCase {
    func testStoppingEndsTheWaitForALockedDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("opencode.db").path

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, """
            CREATE TABLE session (id TEXT, data TEXT);
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            BEGIN EXCLUSIVE;
            INSERT INTO message VALUES ('m', 's', 0, '{}');
            """, nil, nil, nil), SQLITE_OK)

        let stopAt = Date().addingTimeInterval(0.2)
        let started = Date()
        AgentOpenCodeReader.readAppended(AgentLogCursor(path: path, provider: .opencode),
                                         shouldContinue: { Date() < stopAt }, line: { _ in })
        let waited = Date().timeIntervalSince(started)
        // Several queries each waited up to two seconds before; now the stop ends the wait.
        XCTAssertLessThan(waited, 0.6)
        sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
    }
}
