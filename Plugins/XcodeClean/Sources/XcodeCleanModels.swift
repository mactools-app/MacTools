import Foundation
import MacToolsPluginKit

enum XcodeCleanCategory: String, CaseIterable, Identifiable, Equatable, Sendable {
    case derivedData
    case deviceSupport
    case archives
    case simulatorCaches
    case previews
    case xcodeAppCaches

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .derivedData:
            return localization.string("category.derivedData.title", defaultValue: "DerivedData")
        case .deviceSupport:
            return localization.string("category.deviceSupport.title", defaultValue: "设备支持文件")
        case .archives:
            return localization.string("category.archives.title", defaultValue: "Archives")
        case .simulatorCaches:
            return localization.string("category.simulatorCaches.title", defaultValue: "模拟器缓存")
        case .previews:
            return localization.string("category.previews.title", defaultValue: "预览缓存")
        case .xcodeAppCaches:
            return localization.string("category.xcodeAppCaches.title", defaultValue: "Xcode 应用缓存")
        }
    }

    var summary: String {
        summary()
    }

    func summary(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .derivedData:
            return localization.string("category.derivedData.summary", defaultValue: "构建中间产物、索引与日志")
        case .deviceSupport:
            return localization.string("category.deviceSupport.summary", defaultValue: "调试旧设备时下载的符号文件")
        case .archives:
            return localization.string("category.archives.summary", defaultValue: "包含已发布版本的归档与 dSYM，谨慎清理")
        case .simulatorCaches:
            return localization.string("category.simulatorCaches.summary", defaultValue: "模拟器运行时缓存，不影响已创建的模拟器设备")
        case .previews:
            return localization.string("category.previews.summary", defaultValue: "SwiftUI 预览的中间渲染缓存")
        case .xcodeAppCaches:
            return localization.string("category.xcodeAppCaches.summary", defaultValue: "Xcode 自身的会话与界面状态缓存")
        }
    }

    var risk: XcodeCleanRisk {
        switch self {
        case .archives:
            return .medium
        default:
            return .low
        }
    }
}

enum XcodeCleanRisk: Equatable, Sendable {
    case low
    case medium
}

enum XcodeCleanSafetyStatus: Equatable, Sendable {
    case allowed
    case outsideAllowedRoot
    case xcodeRunning
    case missing

    var isCleanable: Bool {
        if case .allowed = self { return true }
        return false
    }
}

enum XcodeCleanScanLogTone: Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

struct XcodeCleanScanLogMessage: Equatable, Sendable {
    let text: String
    let tone: XcodeCleanScanLogTone
}

struct XcodeCleanScanLogEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let tone: XcodeCleanScanLogTone
}

struct XcodeCleanCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let category: XcodeCleanCategory
    let path: String
    let sizeBytes: Int64
    let safety: XcodeCleanSafetyStatus
}

struct XcodeCleanCategorySummary: Equatable, Sendable {
    let category: XcodeCleanCategory
    let candidateCount: Int
    let totalBytes: Int64
}

struct XcodeCleanScanResult: Equatable, Sendable {
    let categories: Set<XcodeCleanCategory>
    let candidates: [XcodeCleanCandidate]
    let scannedAt: Date

    var cleanableCandidates: [XcodeCleanCandidate] {
        candidates.filter { $0.safety.isCleanable }
    }

    var cleanableSizeBytes: Int64 {
        cleanableCandidates.reduce(0) { $0 + max($1.sizeBytes, 0) }
    }

    var protectedCount: Int {
        candidates.count - cleanableCandidates.count
    }

    func summary(for category: XcodeCleanCategory) -> XcodeCleanCategorySummary {
        let scoped = candidates.filter { $0.category == category }
        let totalBytes = scoped.reduce(Int64(0)) { $0 + max($1.sizeBytes, 0) }
        return XcodeCleanCategorySummary(
            category: category,
            candidateCount: scoped.count,
            totalBytes: totalBytes
        )
    }
}

struct XcodeCleanExecutionItemResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case removed(reclaimedBytes: Int64)
        case skipped(XcodeCleanSafetyStatus)
        case failed(message: String)
    }

    let candidateID: XcodeCleanCandidate.ID
    let path: String
    let outcome: Outcome

    var reclaimedBytes: Int64 {
        if case let .removed(reclaimedBytes) = outcome {
            return max(reclaimedBytes, 0)
        }
        return 0
    }
}

struct XcodeCleanExecutionResult: Equatable, Sendable {
    let itemResults: [XcodeCleanExecutionItemResult]

    var removedCount: Int {
        itemResults.filter {
            if case .removed = $0.outcome { return true }
            return false
        }.count
    }

    var skippedCount: Int {
        itemResults.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }.count
    }

    var failedCount: Int {
        itemResults.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
    }

    var reclaimedBytes: Int64 {
        itemResults.reduce(0) { $0 + $1.reclaimedBytes }
    }
}

enum XcodeCleanByteFormatter {
    static func string(fromByteCount bytes: Int64) -> String {
        max(bytes, 0).formatted(
            ByteCountFormatStyle(style: .file, spellsOutZero: false).locale(PluginRuntimeLocalization.locale)
        )
    }
}
