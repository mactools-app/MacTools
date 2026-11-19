import AppKit
import Foundation
import Network
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class TailscalePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        TailscalePluginProvider(context: context)
    }
}

@MainActor
private struct TailscalePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [TailscalePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class TailscalePlugin:
    MacToolsPlugin, PluginCommandProviding, PluginActionProviding {

    private enum ActionID {
        static let toggle = "toggle"
        static let openAdminConsole = "open-admin-console"
    }

    private enum CommandID {
        static let toggle = "toggle"
    }

    private enum ControlID {
        static let refresh = "refresh"
        static let favorites = "favorites"
        static let peers = "peers"
        static let local = "local"
        static let pinPrefix = "pin."
        static let copyPrefix = "copy."
        static let exitNodes = "exit-nodes"
        static let exitOff = "exit-off"
        static let exitPrefix = "exit."
        static let pingPrefix = "ping."
    }

    private static let favoritesKey = "favorite-device-ids"

    // MARK: - Panel items

    var panelItems: [PluginPanelItem] {
        [
            .row(
                id: "control",
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] in self?.handleAction($0) }
            ),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: "Tailscale"),
                systemImage: metadata.iconName,
                control: status.connection == .needsLogin ? .button : .toggle,
                state: rowState,
                menuActionBehavior: rowDescriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "tailscale",
            title: localization.string("metadata.title", defaultValue: "Tailscale"),
            iconName: "network",
            iconTint: Color(nsColor: .systemTeal),
            order: 120,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看 Tailscale 连接状态并快速切换"
            )
        )
    }

    var rowDescriptor: PluginPanelRowDescriptor {
        if status.connection == .needsLogin {
            return PluginPanelRowDescriptor(
                controlStyle: .button, menuActionBehavior: .dismissBeforeHandling,
                buttonTitle: localization.string("login.title", defaultValue: "登录 Tailscale")
            )
        }
        return PluginPanelRowDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented)
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var rowState: PluginPanelRowState {
        let issue = operationError ?? (status.connection == .needsLogin ? nil : statusIssue)
        return PluginPanelRowState(
            subtitle: issue ?? connectionSubtitle,
            isOn: status.connection == .running,
            isEnabled: (status.connection.canToggle || status.connection == .needsLogin) && !isBusy,
            isAvailable: true,
            detail: deviceDetail,
            errorMessage: issue
        )
    }

    private var connectionSubtitle: String {
        switch status.connection {
        case .running: localization.string("status.running", defaultValue: "已连接")
        case .stopped: localization.string("status.stopped", defaultValue: "已断开")
        case .needsLogin: localization.string("status.needsLogin", defaultValue: "需要登录 Tailscale")
        default: localization.string("status.checking", defaultValue: "正在检测状态…")
        }
    }

    private var statusIssue: String? {
        switch status.connection {
        case .cliUnavailable:
            localization.string("status.cliUnavailable", defaultValue: "未找到 Tailscale 命令行工具")
        case .clientUnavailable:
            localization.string("status.clientUnavailable", defaultValue: "Tailscale 未运行，请先打开客户端")
        case .needsLogin:
            localization.string("status.needsLogin", defaultValue: "需要登录 Tailscale")
        case .failed:
            localization.string("status.failed", defaultValue: "无法读取 Tailscale 状态，请重试")
        default: nil
        }
    }

    // MARK: - Private

    private let localization: PluginLocalization
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "TailscalePlugin"
    )
    private var status = TailscaleStatus(connection: .checking)
    private var operationError: String?
    private var isBusy = false
    private var storage: (any PluginStorage)?
    private var favorites = Set<String>()
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private var wakeObserver: (any NSObjectProtocol)?
    private var activationID: UUID?
    private var exitTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pingingDeviceID: String?
    private var pingResult: (deviceID: String, result: TailscalePingResult)?
    private let locateCLI: () -> String?
    private let runCLI: (String, [String]) async -> TailscaleCommandResult
    private let copy: (String) -> Void
    private let openURL: (URL) -> Bool

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        locateCLI: @escaping () -> String? = TailscaleCLI.locate,
        runCLI: @escaping (String, [String]) async -> TailscaleCommandResult = TailscaleCLI.run,
        copy: @escaping (String) -> Void = { value in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.localization = localization
        self.locateCLI = locateCLI
        self.runCLI = runCLI
        self.copy = copy
        self.openURL = openURL
    }

    // MARK: - Lifecycle

    func activate(context: PluginRuntimeContext) {
        guard activationID == nil else { return }
        activationID = UUID()
        storage = context.storage
        favorites = Set(context.storage.stringArray(forKey: Self.favoritesKey) ?? [])
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleEventRefresh() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleEventRefresh() }
        }
        monitor.start(queue: DispatchQueue(label: "MacTools.Tailscale.Network"))
        networkMonitor = monitor

        // Local network events do not cover changes made in the Tailscale client.
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.refreshStatus()
            }
        }
        refreshStatus()
    }

    func deactivate(reason: PluginDeactivationReason) {
        activationID = nil
        refreshTask?.cancel()
        refreshTask = nil
        periodicTask?.cancel()
        periodicTask = nil
        eventTask?.cancel()
        eventTask = nil
        exitTask?.cancel()
        exitTask = nil
        loginTask?.cancel()
        loginTask = nil
        pingTask?.cancel()
        pingTask = nil
        pingingDeviceID = nil
        pingResult = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        storage = nil
        favorites.removeAll()
        status = TailscaleStatus(connection: .checking)
        operationError = nil
        isBusy = false
    }

    func refresh() {
        refreshStatus()
    }

    // MARK: - Commands

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: CommandID.toggle,
                title: localization.string("action.toggle.title", defaultValue: "切换 Tailscale 连接"),
                description: localization.string(
                    "action.toggle.description",
                    defaultValue: "在已连接和已断开之间切换 Tailscale。"
                ),
                systemImage: metadata.iconName
            ),
        ]
    }

    func handleCommand(id: String) {
        guard id == CommandID.toggle else { return }
        Task { @MainActor [weak self] in
            await self?.performToggle()
        }
    }

    // MARK: - Actions

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("action.toggle.title", defaultValue: "切换 Tailscale 连接"),
                description: localization.string(
                    "action.toggle.description",
                    defaultValue: "在已连接和已断开之间切换 Tailscale。"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "Tailscale"),
                    "tailscale",
                    "vpn",
                    "connect",
                    "disconnect",
                    "连接",
                    "断开",
                    "切换",
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.openAdminConsole),
                title: localization.string(
                    "action.openAdminConsole.title",
                    defaultValue: "打开 Tailscale 管理控制台"
                ),
                description: localization.string(
                    "action.openAdminConsole.description",
                    defaultValue: "在浏览器中打开 Tailscale 管理控制台。"
                ),
                keywords: [
                    "tailscale",
                    "admin",
                    "console",
                    "管理",
                    "控制台",
                ],
                systemImage: "globe",
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            switch invocation.reference.key.actionID {
            case ActionID.toggle:
                return await self.performToggle()
                    ? .succeeded()
                    : .failed(message: self.statusIssue ?? self.operationError ?? self.localization.string(
                        "error.toggleFailed",
                        defaultValue: "无法切换 Tailscale 连接状态。"
                    ))
            case ActionID.openAdminConsole:
                self.openAdminConsole()
                return .succeeded()
            default:
                return .failed(message: self.localization.string(
                    "error.unknownAction",
                    defaultValue: "未知操作。"
                ))
            }
        }
    }

    // MARK: - Panel actions

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isOn):
            Task { @MainActor [weak self] in
                await self?.setConnected(isOn)
            }
        case let .invokeAction(controlID):
            if controlID == "execute", loginTask == nil, status.connection == .needsLogin, !isBusy {
                loginTask = Task { [weak self] in await self?.startLogin() }
            } else if controlID == ControlID.refresh {
                if operationError != nil {
                    operationError = nil
                    onStateChange?()
                }
                refreshStatus()
            } else {
                handleDeviceAction(controlID)
            }
        default:
            break
        }
    }

    // MARK: - Work

    private func startLogin() async {
        guard let activationID else { return }
        defer {
            if self.activationID == activationID {
                loginTask = nil
                isBusy = false
                onStateChange?()
            }
        }
        let pendingRefresh = refreshTask
        pendingRefresh?.cancel()
        refreshTask = nil
        isBusy = true
        operationError = nil
        onStateChange?()
        await pendingRefresh?.value
        guard self.activationID == activationID, !Task.isCancelled else { return }
        var updated = await readStatus()
        guard self.activationID == activationID, !Task.isCancelled else { return }
        if updated.connection == .needsLogin, updated.loginURL == nil, let cli = locateCLI() {
            _ = await runCLI(cli, ["up", "--timeout=10s"])
            guard self.activationID == activationID, !Task.isCancelled else { return }
            updated = await readStatus()
        }
        guard self.activationID == activationID, !Task.isCancelled else { return }
        applyStatus(updated)
        guard updated.connection == .needsLogin else { return }
        if let url = updated.loginURL, openURL(url) { return }
        operationError = localization.string("login.failed", defaultValue: "无法打开登录页，请检查网络后重试。")
    }

    func refreshStatus() {
        guard activationID != nil, refreshTask == nil, !isBusy else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let updated = await readStatus()
            guard !Task.isCancelled else { return }
            refreshTask = nil
            if status != updated {
                applyStatus(updated)
                onStateChange?()
            }
        }
    }

    private func scheduleEventRefresh() {
        guard activationID != nil else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.refreshStatus()
        }
    }

    private func performToggle() async -> Bool {
        await setConnected(status.connection != .running)
    }

    private func setConnected(_ enabled: Bool) async -> Bool {
        guard let activationID, status.connection.canToggle, !isBusy else { return false }
        guard let cli = locateCLI() else {
            status = TailscaleStatus(connection: .cliUnavailable)
            onStateChange?()
            return false
        }

        let pendingRefresh = refreshTask
        pendingRefresh?.cancel()
        refreshTask = nil
        isBusy = true
        operationError = nil
        onStateChange?()
        defer {
            if self.activationID == activationID {
                isBusy = false
                onStateChange?()
            }
        }
        await pendingRefresh?.value
        guard self.activationID == activationID, !Task.isCancelled else { return false }
        let result = await runCLI(cli, [enabled ? "up" : "down"])
        guard self.activationID == activationID else { return false }
        let updated = await readStatus()
        guard self.activationID == activationID else { return false }
        applyStatus(updated)
        let succeeded = result.succeeded && status.connection == (enabled ? .running : .stopped)
        if succeeded {
            logger.info("Tailscale \(enabled ? "connected" : "disconnected", privacy: .public)")
        } else {
            switch result.failure {
            case .clientUnavailable:
                operationError = localization.string("status.clientUnavailable", defaultValue: "Tailscale 未运行，请先打开客户端")
            case .needsLogin:
                operationError = localization.string("status.needsLogin", defaultValue: "需要登录 Tailscale")
            default:
                operationError = localization.string("error.toggleFailed", defaultValue: "无法切换 Tailscale 连接状态。")
            }
            logger.error("Failed to \(enabled ? "connect" : "disconnect", privacy: .public) Tailscale")
        }
        return succeeded
    }

    private func readStatus() async -> TailscaleStatus {
        guard let cli = locateCLI() else {
            return TailscaleStatus(connection: .cliUnavailable)
        }
        return TailscaleStatus(result: await runCLI(cli, ["status", "--json"]))
    }

    private func applyStatus(_ updated: TailscaleStatus) {
        if updated.connection != .running || status.local?.id != updated.local?.id {
            pingTask?.cancel()
            pingTask = nil
            pingingDeviceID = nil
            pingResult = nil
        }
        if let pingResult {
            let previousAddress = status.peers.first { $0.id == pingResult.deviceID }?.commandAddress
            let currentAddress = updated.peers.first { $0.id == pingResult.deviceID }?.commandAddress
            if previousAddress != currentAddress { self.pingResult = nil }
        }
        status = updated
    }

    private func openAdminConsole() {
        let url = URL(string: "https://login.tailscale.com/admin/machines")!
        NSWorkspace.shared.open(url)
    }
}

private extension TailscalePlugin {
    var deviceDetail: PluginPanelDetail {
        var controls: [PluginPanelControl] = []
        var panels: [PluginPanelNavigationSecondaryPanel] = []

        if let local = status.local {
            controls += copyControls(for: local, key: ControlID.local)
        }

        if status.connection == .running {
            appendExitNodes(to: &controls, panels: &panels)
        }

        let (pinned, other) = (status.peers.filter { favorites.contains($0.id) },
                               status.peers.filter { !favorites.contains($0.id) })
        let groups = [
            (ControlID.favorites, localization.string("devices.favorites", defaultValue: "常用设备"), pinned),
            (ControlID.peers, localization.string("devices.peers", defaultValue: "其他设备"), other),
        ]
        for (id, title, devices) in groups where !devices.isEmpty {
            controls.append(PluginPanelControl(
                id: id, kind: .navigationList, options: devices.map(deviceOption), selectedOptionID: nil,
                dateValue: nil, minimumDate: nil, displayedComponents: nil, datePickerStyle: nil,
                sectionTitle: title, isEnabled: true
            ))
            for device in devices {
                let isPinned = favorites.contains(device.id)
                let pin = actionRow(
                    id: ControlID.pinPrefix + device.id,
                    title: isPinned
                        ? localization.string("devices.unpin", defaultValue: "取消置顶")
                        : localization.string("devices.pin", defaultValue: "置顶为常用设备"),
                    icon: isPinned ? "pin.slash" : "pin"
                )
                let actions = copyControls(for: device, key: "peer.\(device.id)") + [pin, pingControl(for: device)]
                panels.append(PluginPanelNavigationSecondaryPanel(
                    controlID: id, optionID: device.id,
                    panel: PluginPanelSecondaryPanel(title: device.name, controls: actions)
                ))
            }
        }
        controls.append(actionRow(
            id: ControlID.refresh,
            title: localization.string("status.refresh", defaultValue: "刷新状态"),
            icon: "arrow.clockwise", enabled: !isBusy
        ))
        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil, navigationSecondaryPanels: panels)
    }

    func deviceOption(_ device: TailscaleStatus.Device) -> PluginPanelControlOption {
        let availability: String? = switch device.online {
        case true?: localization.string("devices.online", defaultValue: "在线")
        case false?: localization.string("devices.offline", defaultValue: "离线")
        case nil: nil
        }
        let subtitle = [availability, device.ips.first].compactMap { $0 }.joined(separator: " · ")
        return PluginPanelControlOption(id: device.id, title: device.name, subtitle: subtitle.isEmpty ? nil : subtitle)
    }

    func appendExitNodes(to controls: inout [PluginPanelControl], panels: inout [PluginPanelNavigationSecondaryPanel]) {
        let section = localization.string("exit.title", defaultValue: "出口节点")
        let candidates = status.peers.filter { $0.exitNodeOption == true && $0.id != status.exitNode?.id }
        if let exit = status.exitNode {
            let name = status.peers.first { $0.id == exit.id }?.name
                ?? localization.string("exit.unknown", defaultValue: "未知设备")
            let current = localization.format("exit.current", defaultValue: "当前：%@", name)
            let subtitle = exit.online == false
                ? current + " · " + localization.string("devices.offline", defaultValue: "离线") : current
            controls.append(actionRow(
                id: ControlID.exitOff, title: localization.string("exit.disable", defaultValue: "关闭出口节点"),
                icon: "globe", section: section + " · " + subtitle, enabled: !isBusy
            ))
        } else {
            controls.append(actionRow(
                id: ControlID.exitOff, title: localization.string("exit.off", defaultValue: "未使用出口节点"),
                icon: "globe", section: section, enabled: false
            ))
        }
        guard !candidates.isEmpty else { return }
        controls.append(PluginPanelControl(
            id: ControlID.exitNodes, kind: .navigationList, options: candidates.map(deviceOption), selectedOptionID: nil,
            dateValue: nil, minimumDate: nil, displayedComponents: nil, datePickerStyle: nil,
            sectionTitle: nil, isEnabled: !isBusy
        ))
        for device in candidates {
            let use = actionRow(
                id: ControlID.exitPrefix + device.id,
                title: localization.string("exit.use", defaultValue: "使用此出口节点"), icon: "globe",
                enabled: device.canUseAsExitNode && !isBusy
            )
            panels.append(PluginPanelNavigationSecondaryPanel(
                controlID: ControlID.exitNodes, optionID: device.id,
                panel: PluginPanelSecondaryPanel(title: device.name, controls: [use])
            ))
        }
    }

    func changeExitNode(to id: String?) {
        guard let activationID, let localID = status.local?.id, !localID.isEmpty,
              status.connection == .running, status.exitNode?.id != id, !isBusy else { return }
        let expectedExit = status.exitNode?.id
        let pendingRefresh = refreshTask
        pendingRefresh?.cancel()
        refreshTask = nil
        isBusy = true
        operationError = nil
        onStateChange?()
        exitTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activationID == activationID {
                    exitTask = nil
                    isBusy = false
                    onStateChange?()
                }
            }
            await pendingRefresh?.value
            guard !Task.isCancelled else { return }
            let before = await readStatus()
            guard !Task.isCancelled else { return }
            applyStatus(before)
            guard before.connection == .running, before.local?.id == localID,
                  before.exitNode?.id == expectedExit, let cli = locateCLI() else {
                recordExitFailure()
                return
            }
            let address: String
            if let id {
                guard let device = before.peers.first(where: { $0.id == id && $0.canUseAsExitNode }),
                      let candidate = device.commandAddress else {
                    recordExitFailure()
                    return
                }
                address = candidate
            } else {
                address = ""
            }
            let result = await runCLI(cli, ["set", "--exit-node=\(address)"])
            guard !Task.isCancelled else { return }
            // The first snapshot may arrive before the backend has applied the preference.
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                }
                let after = await readStatus()
                guard !Task.isCancelled else { return }
                applyStatus(after)
                if result.succeeded, after.connection == .running, after.local?.id == localID,
                   after.exitNode?.id == id { return }
                if !result.succeeded { break }
            }
            recordExitFailure()
        }
    }

    func recordExitFailure() {
        operationError = localization.string("exit.failed", defaultValue: "未能确认出口节点已切换，请重试")
    }

    func pingControl(for device: TailscaleStatus.Device) -> PluginPanelControl {
        let running = pingingDeviceID == device.id
        let result = pingResult.flatMap { $0.deviceID == device.id ? $0.result : nil }
        let title = running ? localization.string("ping.running", defaultValue: "正在测试连通性…")
            : localization.string("ping.run", defaultValue: "测试连通性")
        return actionRow(
            id: ControlID.pingPrefix + device.id, title: title, icon: "waveform.path",
            section: result.map(pingMessage), enabled: !isBusy && pingTask == nil && device.commandAddress != nil
        )
    }

    func pingMessage(_ result: TailscalePingResult) -> String {
        switch result {
        case .direct: localization.string("ping.direct", defaultValue: "可达 · 直连")
        case .derp: localization.string("ping.derp", defaultValue: "可达 · DERP 中继")
        case .peerRelay: localization.string("ping.peerRelay", defaultValue: "可达 · 设备中继")
        case .reachable: localization.string("ping.reachable", defaultValue: "可达")
        case .noReply: localization.string("ping.noReply", defaultValue: "设备未响应")
        case .failed: localization.string("ping.failed", defaultValue: "无法测试连通性")
        }
    }

    func pingDevice(_ id: String) {
        guard pingTask == nil, !isBusy, let activationID, status.connection == .running,
              let device = status.peers.first(where: { $0.id == id }), let ip = device.commandAddress,
              let cli = locateCLI() else { return }
        pingResult = nil
        pingingDeviceID = id
        onStateChange?()
        pingTask = Task { [weak self] in
            guard let self else { return }
            let result = await runCLI(cli, ["ping", "--c=3", "--timeout=2s", ip])
            guard !Task.isCancelled, self.activationID == activationID else { return }
            pingTask = nil
            pingingDeviceID = nil
            if status.peers.contains(where: { $0.id == id && $0.commandAddress == ip }) {
                pingResult = (id, TailscalePingResult(result))
            }
            onStateChange?()
        }
    }

    func copyValues(for device: TailscaleStatus.Device) -> [(value: String, label: String)] {
        var values = device.ips.map { ($0, localization.string("devices.copyIP", defaultValue: "复制 IP")) }
        if status.magicDNSEnabled, let dns = device.magicDNSName {
            values.append((dns, localization.string("devices.copyDNS", defaultValue: "复制 MagicDNS")))
        }
        return values
    }

    func copyControls(for device: TailscaleStatus.Device, key: String) -> [PluginPanelControl] {
        copyValues(for: device).enumerated().map { index, item in
            actionRow(
                id: copyID(key: key, value: item.value), title: item.label, icon: "doc.on.doc",
                section: key == ControlID.local && index == 0
                    ? localization.string("devices.local", defaultValue: "本机") + " · " + item.value
                    : item.value
            )
        }
    }

    func copyID(key: String, value: String) -> String {
        "\(ControlID.copyPrefix)\(key)/\(value)"
    }

    func actionRow(
        id: String, title: String, icon: String, section: String? = nil, enabled: Bool = true
    ) -> PluginPanelControl {
        PluginPanelControl(
            id: id, kind: .actionRow, options: [], selectedOptionID: nil,
            dateValue: nil, minimumDate: nil, displayedComponents: nil, datePickerStyle: nil,
            sectionTitle: section, actionTitle: title, actionIconSystemName: icon, isEnabled: enabled
        )
    }

    func handleDeviceAction(_ controlID: String) {
        if controlID == ControlID.exitOff {
            changeExitNode(to: nil)
            return
        }
        if controlID.hasPrefix(ControlID.exitPrefix) {
            changeExitNode(to: String(controlID.dropFirst(ControlID.exitPrefix.count)))
            return
        }
        if controlID.hasPrefix(ControlID.pingPrefix) {
            pingDevice(String(controlID.dropFirst(ControlID.pingPrefix.count)))
            return
        }
        if controlID.hasPrefix(ControlID.pinPrefix), let storage {
            let id = String(controlID.dropFirst(ControlID.pinPrefix.count))
            guard status.peers.contains(where: { $0.id == id }) else { return }
            if favorites.remove(id) == nil { favorites.insert(id) }
            storage.set(favorites.sorted(), forKey: Self.favoritesKey)
            onStateChange?()
            return
        }

        guard controlID.hasPrefix(ControlID.copyPrefix) else { return }
        if let local = status.local, copyDeviceValue(controlID, device: local, key: ControlID.local) { return }
        for device in status.peers where copyDeviceValue(controlID, device: device, key: "peer.\(device.id)") {
            return
        }
    }

    func copyDeviceValue(_ controlID: String, device: TailscaleStatus.Device, key: String) -> Bool {
        guard let item = copyValues(for: device).first(where: { copyID(key: key, value: $0.value) == controlID }) else {
            return false
        }
        copy(item.value)
        return true
    }
}
