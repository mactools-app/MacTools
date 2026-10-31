import AppKit
import Combine
import Foundation
import MacToolsPluginKit
import PermissionFlow
import SystemSettingsKit

private final class PermissionNotificationObserver: @unchecked Sendable {
    let notificationCenter: NotificationCenter
    let token: NSObjectProtocol

    init(notificationCenter: NotificationCenter, token: NSObjectProtocol) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    deinit {
        notificationCenter.removeObserver(token)
    }
}

enum HostPermissionKind: String, CaseIterable, Hashable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording
    case calendarFullAccess
    case automation
    case systemAudioRecording
    case fullDiskAccess
    case finderExtension

    static func resolve(
        permissionID: String,
        pluginKind: PluginPermissionKind
    ) -> HostPermissionKind {
        switch permissionID {
        case "system-audio-recording":
            return .systemAudioRecording
        case "full-disk-access":
            return .fullDiskAccess
        case "finder-extension":
            return .finderExtension
        default:
            break
        }

        return switch pluginKind {
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        case .calendarFullAccess: .calendarFullAccess
        case .automation: .automation
        case .screenRecording: .screenRecording
        case .finderExtension: .finderExtension
        }
    }

    var sortOrder: Int {
        switch self {
        case .microphone: 8
        case .accessibility: 0
        case .inputMonitoring: 1
        case .screenRecording: 2
        case .systemAudioRecording: 3
        case .calendarFullAccess: 4
        case .automation: 5
        case .fullDiskAccess: 6
        case .finderExtension: 7
        }
    }
}

enum PermissionCenterStatus: Int, Equatable, Sendable {
    case attention
    case onDemand
    case granted
}

struct PermissionCenterRequirement: Equatable, Sendable {
    let pluginID: String
    let pluginTitle: String
    let permissionID: String
    let kind: HostPermissionKind
    let description: String
    let isGranted: Bool
    let footnote: String?
    let statusText: String?
    let statusSystemImage: String?
    let statusTone: PluginStatusTone?
}

struct PermissionCenterAffectedFeature: Identifiable, Equatable, Sendable {
    let pluginID: String
    let pluginTitle: String
    let permissionID: String
    let description: String
    let isGranted: Bool
    let footnote: String?
    let status: PermissionCenterStatus
    let statusText: String?
    let statusSystemImage: String?
    let statusTone: PluginStatusTone?

    var id: String {
        "\(pluginID).permission.\(permissionID)"
    }
}

struct PermissionCenterItem: Identifiable, Equatable, Sendable {
    let kind: HostPermissionKind
    let status: PermissionCenterStatus
    let affectedFeatures: [PermissionCenterAffectedFeature]
    let statusText: String
    let statusSystemImage: String
    let statusTone: PluginStatusTone
    let footnote: String?

    var id: String { kind.rawValue }
    var actionTarget: PermissionCenterAffectedFeature? {
        affectedFeatures.first(where: { $0.status != .granted }) ?? affectedFeatures.first
    }
}

enum PermissionCenterAggregator {
    static func aggregate(
        _ requirements: [PermissionCenterRequirement]
    ) -> [PermissionCenterItem] {
        Dictionary(grouping: requirements, by: \.kind)
            .map { kind, requirements in
                let sortedRequirements = requirements.sorted {
                    if $0.pluginTitle.localizedStandardCompare($1.pluginTitle) == .orderedSame {
                        if $0.pluginID == $1.pluginID {
                            return $0.permissionID < $1.permissionID
                        }
                        return $0.pluginID < $1.pluginID
                    }
                    return $0.pluginTitle.localizedStandardCompare($1.pluginTitle) == .orderedAscending
                }
                let affectedFeatures = sortedRequirements
                    .map {
                        PermissionCenterAffectedFeature(
                            pluginID: $0.pluginID,
                            pluginTitle: $0.pluginTitle,
                            permissionID: $0.permissionID,
                            description: $0.description,
                            isGranted: $0.isGranted,
                            footnote: $0.footnote,
                            status: featureStatus(for: $0),
                            statusText: $0.statusText,
                            statusSystemImage: $0.statusSystemImage,
                            statusTone: $0.statusTone
                        )
                    }

                let attentionRequirements = sortedRequirements.filter {
                    featureStatus(for: $0) == .attention
                }
                let onDemandRequirements = sortedRequirements.filter {
                    featureStatus(for: $0) == .onDemand
                }
                let status: PermissionCenterStatus
                if !attentionRequirements.isEmpty {
                    status = .attention
                } else if !onDemandRequirements.isEmpty {
                    status = .onDemand
                } else {
                    status = .granted
                }

                let representative: PermissionCenterRequirement? = switch status {
                case .attention:
                    attentionRequirements.first(where: { $0.footnote != nil })
                        ?? attentionRequirements.first
                case .onDemand:
                    onDemandRequirements.first
                case .granted:
                    sortedRequirements.first
                }
                let statusPresentation = statusPresentation(
                    status: status,
                    representative: representative
                )
                return PermissionCenterItem(
                    kind: kind,
                    status: status,
                    affectedFeatures: affectedFeatures,
                    statusText: statusPresentation.text,
                    statusSystemImage: statusPresentation.systemImage,
                    statusTone: statusPresentation.tone,
                    footnote: centerFootnote(
                        for: kind
                    )
                )
            }
            .sorted {
                if $0.status.rawValue != $1.status.rawValue {
                    return $0.status.rawValue < $1.status.rawValue
                }
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
    }

    private static func featureStatus(
        for requirement: PermissionCenterRequirement
    ) -> PermissionCenterStatus {
        if requirement.statusTone == .neutral {
            return .onDemand
        }
        return requirement.isGranted ? .granted : .attention
    }

    private static func statusPresentation(
        status: PermissionCenterStatus,
        representative: PermissionCenterRequirement?
    ) -> (text: String, systemImage: String, tone: PluginStatusTone) {
        switch status {
        case .granted:
            return (
                AppL10n.plugins("plugin.permission.granted", defaultValue: "已授权"),
                "checkmark.shield.fill",
                .positive
            )
        case .onDemand:
            return (
                representative?.statusText
                    ?? AppL10n.settings("permissions.status.onDemand", defaultValue: "按需请求"),
                representative?.statusSystemImage ?? "cursorarrow.click.2",
                .neutral
            )
        case .attention:
            return (
                representative?.statusText
                    ?? AppL10n.plugins("plugin.permission.notGranted", defaultValue: "未授权"),
                representative?.statusSystemImage ?? "exclamationmark.triangle.fill",
                representative?.statusTone ?? .caution
            )
        }
    }

    private static func centerFootnote(
        for kind: HostPermissionKind
    ) -> String? {
        switch kind {
        case .fullDiskAccess:
            return AppL10n.settings(
                "permissions.fullDiskAccess.restartNote",
                defaultValue: "更改完全磁盘访问后，可能需要重新打开 MacTools 才能刷新完整访问范围。"
            )
        case .automation:
            return AppL10n.settings(
                "permissions.automation.onDemandNote",
                defaultValue: "自动化权限由 macOS 在功能首次控制目标 App 时按需请求。"
            )
        case .systemAudioRecording:
            return AppL10n.settings(
                "permissions.systemAudio.onDemandNote",
                defaultValue: "系统音频录制由相关功能首次捕获音频时按需请求。"
            )
        default:
            return nil
        }
    }
}

@MainActor
final class PermissionCoordinator: ObservableObject {
    typealias SpecializedActionHandler = (_ pluginID: String, _ permissionID: String) -> Void
    typealias RefreshHandler = (_ targets: [PermissionCenterAffectedFeature]) -> Void
    typealias GuidanceHandler = @MainActor (_ kind: HostPermissionKind, _ sourceFrame: CGRect?) -> Void

    @Published private(set) var items: [PermissionCenterItem] = []

    private let specializedActionHandler: SpecializedActionHandler
    private let refreshHandler: RefreshHandler
    private let guidanceHandler: GuidanceHandler
    private var activationObserver: PermissionNotificationObserver?
    private var pendingActivationRefreshCount = 0
    private var activationRefreshTarget: PermissionCenterAffectedFeature?

    init(
        notificationCenter: NotificationCenter = .default,
        specializedActionHandler: @escaping SpecializedActionHandler,
        refreshHandler: @escaping RefreshHandler,
        guidanceHandler: @escaping GuidanceHandler = PermissionFlowGuidancePresenter.shared.present
    ) {
        self.specializedActionHandler = specializedActionHandler
        self.refreshHandler = refreshHandler
        self.guidanceHandler = guidanceHandler
        let token = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingActivationRefreshCount > 0 else {
                    return
                }
                let targets = self.activationRefreshTarget.map { [$0] } ?? []
                self.pendingActivationRefreshCount -= 1
                if self.pendingActivationRefreshCount == 0 {
                    self.activationRefreshTarget = nil
                }
                self.refreshHandler(targets)
            }
        }
        activationObserver = PermissionNotificationObserver(
            notificationCenter: notificationCenter,
            token: token
        )
    }

    func replaceRequirements(_ requirements: [PermissionCenterRequirement]) {
        items = PermissionCenterAggregator.aggregate(requirements)
        if let target = activationRefreshTarget,
           items.lazy.flatMap(\.affectedFeatures).contains(where: {
               $0.id == target.id && $0.status == .granted
           }) {
            pendingActivationRefreshCount = 0
            activationRefreshTarget = nil
        }
    }

    @discardableResult
    func performAction(
        pluginID: String,
        permissionID: String,
        sourceFrame: CGRect? = nil
    ) -> Bool {
        guard let item = items.first(where: { item in
            item.affectedFeatures.contains {
                $0.pluginID == pluginID && $0.permissionID == permissionID
            }
        }), let target = item.affectedFeatures.first(where: {
            $0.pluginID == pluginID && $0.permissionID == permissionID
        }) else {
            return false
        }
        guard target.status != .granted else {
            refreshHandler([target])
            return true
        }
        performAction(kind: item.kind, target: target, sourceFrame: sourceFrame)
        return true
    }

    func performAction(
        for item: PermissionCenterItem,
        sourceFrame: CGRect? = nil
    ) {
        guard item.status != .granted else {
            refreshHandler(item.affectedFeatures)
            return
        }
        guard let target = item.actionTarget else { return }
        performAction(kind: item.kind, target: target, sourceFrame: sourceFrame)
    }

    private func performAction(
        kind: HostPermissionKind,
        target: PermissionCenterAffectedFeature,
        sourceFrame: CGRect?
    ) {
        switch kind {
        case .accessibility, .inputMonitoring, .screenRecording, .automation:
            pendingActivationRefreshCount = 1
            activationRefreshTarget = nil
            guidanceHandler(kind, sourceFrame)
        case .fullDiskAccess:
            pendingActivationRefreshCount = 1
            activationRefreshTarget = target
            guidanceHandler(kind, sourceFrame)
        case .calendarFullAccess,
             .systemAudioRecording,
             .finderExtension, .microphone:
            pendingActivationRefreshCount = kind == .systemAudioRecording ? 2 : 1
            activationRefreshTarget = target
            specializedActionHandler(target.pluginID, target.permissionID)
        }
    }

    func refresh() {
        refreshHandler([])
    }
}

@MainActor
final class PermissionFlowGuidancePresenter {
    static let shared = PermissionFlowGuidancePresenter()

    private let controller = PermissionFlow.makeController(
        configuration: PermissionFlowConfiguration(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false,
            localeIdentifier: PluginRuntimeLocalization.locale.identifier
        )
    )

    func present(kind: HostPermissionKind, sourceFrame: CGRect?) {
        controller.setLocaleIdentifier(PluginRuntimeLocalization.locale.identifier)
        switch kind {
        case .accessibility:
            authorize(.accessibility, sourceFrame: sourceFrame)
        case .inputMonitoring:
            authorize(.inputMonitoring, sourceFrame: sourceFrame)
        case .screenRecording:
            authorize(.screenRecording, sourceFrame: sourceFrame)
        case .fullDiskAccess:
            authorize(.fullDiskAccess, sourceFrame: sourceFrame)
        case .automation:
            SystemSettings.open(.privacy(anchor: .privacyAutomation))
        case .calendarFullAccess:
            SystemSettings.open(.privacy(anchor: .privacyCalendars))
        case .systemAudioRecording:
            SystemSettings.open(.privacy(anchor: .privacyAudioCapture))
        case .finderExtension, .microphone:
            break
        }
    }

    private func authorize(_ pane: PermissionFlowPane, sourceFrame: CGRect?) {
        controller.authorize(
            pane: pane,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: sourceFrame
        )
    }
}
