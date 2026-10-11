import Foundation
import MacToolsPluginKit
@testable import SystemDataPlugin

// MARK: - Immediate scanner

/// Returns a fixed result right away. Used for completion and failure paths
/// that must not depend on timing.
struct SystemDataImmediateScanner: SystemDataScanning {
    private let result: SystemDataScanResult?
    private let failureMessage: String?

    init(result: SystemDataScanResult) {
        self.result = result
        self.failureMessage = nil
    }

    init(failureMessage: String) {
        self.result = nil
        self.failureMessage = failureMessage
    }

    func scan(
        progress: @escaping @Sendable (SystemDataScanProgress) -> Void
    ) async throws -> SystemDataScanResult {
        progress(
            SystemDataScanProgress(
                completedItems: 1,
                totalItems: 1,
                directoriesRead: 1,
                bytesFound: 0
            )
        )
        if let failureMessage {
            throw NSError(
                domain: "SystemDataTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failureMessage]
            )
        }
        guard let result else {
            throw NSError(
                domain: "SystemDataTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "missing fixture result"]
            )
        }
        return result
    }
}

// MARK: - Manual scanner

/// Registers every scan with a stable ID and stays suspended until the test
/// explicitly finishes or fails it. Cancellation does not resume it, so tests
/// can deliver results late and prove the controller drops stale work.
final class SystemDataManualScanner: SystemDataScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var registeredIDs: [UUID] = []
    private var handlers: [UUID: @Sendable (SystemDataScanProgress) -> Void] = [:]
    private var continuations: [UUID: CheckedContinuation<SystemDataScanResult, Error>] = [:]

    var ids: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return registeredIDs
    }

    func scan(
        progress: @escaping @Sendable (SystemDataScanProgress) -> Void
    ) async throws -> SystemDataScanResult {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            registeredIDs.append(id)
            handlers[id] = progress
            continuations[id] = continuation
            lock.unlock()
        }
    }

    /// Delivers progress to one scan only, so a test can target a scan that is
    /// still registered without waking unrelated handlers.
    func emit(_ progress: SystemDataScanProgress, to id: UUID) {
        lock.lock()
        let handler = handlers[id]
        lock.unlock()
        handler?(progress)
    }

    func finish(id: UUID, result: SystemDataScanResult) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func fail(id: UUID, error: Error) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

// MARK: - Fixtures

enum SystemDataTestFixtures {
    /// Two groups: one plain path item and one children probe, so ordering,
    /// badge merging, and child splitting all have data to work with.
    static let definitions: [SystemDataGroupDefinition] = [
        SystemDataGroupDefinition(
            id: "group-a",
            label: .literal("Group A"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "a1",
                    label: .literal("A1"),
                    path: "/tmp/system-data-fixture/a1",
                    badge: .safe,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "group-b",
            label: .literal("Group B"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "b1",
                    label: .literal("B1"),
                    path: "/tmp/system-data-fixture/b1",
                    badge: .review,
                    kind: .children()
                ),
            ]
        ),
    ]

    static func result(a1Bytes: Int64 = 1000) -> SystemDataScanResult {
        SystemDataScanResult(
            results: [
                SystemDataJobResult(itemID: "a1", status: .measured(bytes: a1Bytes)),
                SystemDataJobResult(
                    itemID: "b1",
                    status: .measured(bytes: 500),
                    children: [
                        SystemDataChildMeasurement(
                            id: "b1.child.alpha",
                            name: "alpha",
                            path: "/tmp/system-data-fixture/b1/alpha",
                            bytes: 300
                        ),
                        SystemDataChildMeasurement(
                            id: "b1.child.beta",
                            name: "beta",
                            path: "/tmp/system-data-fixture/b1/beta",
                            bytes: 200
                        ),
                    ]
                ),
            ],
            availableBytes: 5000,
            capacityBytes: 100_000,
            finishedAt: Date()
        )
    }

    static func progress(completed: Int, bytes: Int64 = 0) -> SystemDataScanProgress {
        SystemDataScanProgress(
            completedItems: completed,
            totalItems: 5,
            directoriesRead: completed,
            bytesFound: bytes
        )
    }
}
