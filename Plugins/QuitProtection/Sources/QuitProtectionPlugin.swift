import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

public final class QuitProtectionPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        QuitProtectionProvider(context: context)
    }
}

@MainActor
private struct QuitProtectionProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] { [QuitProtectionPlugin(context: context)] }
}

@MainActor
final class QuitProtectionPlugin: MacToolsPlugin, PluginApplicationActivityStateHandling, AccessibilityPermissionRefreshing,
    PluginPhysicalInputCompatibilityConsuming {
    private struct Settings: Codable {
        var isEnabled = false
        var showsFeedback = true
        var quit = QuitProtectionRule()

        // Preserve the effective state of settings saved with two switches.
        var protectionEnabled: Bool {
            get { isEnabled && quit.isEnabled }
            set {
                isEnabled = newValue
                quit.isEnabled = newValue
            }
        }
    }

    private static let storageKey = "settings"
    private static let accessibility = "accessibility"
    private static let inputMonitoring = "input-monitoring"
    private let storage: any PluginStorage
    private let localization: PluginLocalization
    private let session = QuitProtectionSession()
    private let feedback = QuitProtectionFeedback()
    private var settings: Settings
    private var active = false
    private var hasCompatibleInputPlugins = false
    private var activity: PluginApplicationActivityState = .interactive
    private var appPicker: NSOpenPanel?
    private var permissionObserver: (any NSObjectProtocol)?

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(context: PluginRuntimeContext) {
        storage = context.storage
        localization = PluginLocalization(bundle: context.resourceBundle)
        settings = storage.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        switch settings.quit.confirmation {
        case let .hold(duration):
            settings.quit.confirmation = .hold(min(.seconds(2), max(.milliseconds(500), duration)))
        case let .doublePress(interval):
            settings.quit.confirmation = .doublePress(min(.seconds(2), max(.milliseconds(500), interval)))
        case .extraModifier:
            // The prototype mode never offered active protection. Recover its
            // settings form without enabling protection on the user's behalf.
            settings.protectionEnabled = false
            settings.quit.confirmation = .hold(.milliseconds(800))
        }
        session.showFeedback = { [weak self] app, state in
            guard let self, self.settings.showsFeedback || state == .chromeUnavailable else { return }
            self.feedback.show(for: app, localization: self.localization, state: state)
        }
        session.hideFeedback = { [weak self] in self?.feedback.hide() }
        session.availabilityChanged = { [weak self] in self?.refresh() }
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "quit-protection", title: text("Quit Protection"), iconName: "shield.lefthalf.filled",
            iconTint: Color(nsColor: .systemBlue), order: 105,
            defaultDescription: text("Prevent accidental quits with a confirmation shortcut.")
        )
    }

    private var protectionStatus: String {
        if !settings.protectionEnabled { return text("Paused") }
        if !hasQuitScope { return text("Choose apps to protect in Settings") }
        if !hasCompatibleInputPlugins { return text("Update Window Switcher or Input Remapping to use Quit Protection.") }
        return text(session.isProtecting ? "Protecting ⌘Q" : "Protection unavailable")
    }

    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "protection", initialPlacement: .featurePanel,
                 descriptor: PluginPanelRowDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented),
                 state: PluginPanelRowState(subtitle: protectionStatus, isOn: settings.protectionEnabled, isEnabled: true,
                                            isAvailable: true, detail: nil, errorMessage: nil)) {
                [weak self] action in
                guard let self, case let .setSwitch(enabled) = action else { return }
                self.settings.protectionEnabled = enabled
                self.save()
            }
        ]
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(id: Self.accessibility, kind: .accessibility, title: text("Accessibility"),
                                        description: text("Intercept and deliver confirmed quit shortcuts.")),
            PluginPermissionRequirement(id: Self.inputMonitoring, kind: .inputMonitoring, title: text("Input Monitoring"),
                                        description: text("Identify the original keyboard shortcut and its destination."))
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        let granted = switch permissionID {
        case Self.accessibility: AXIsProcessTrusted() && CGPreflightPostEventAccess()
        case Self.inputMonitoring: CGPreflightListenEventAccess()
        default: false
        }
        return PluginPermissionState(isGranted: granted, footnote: nil)
    }

    func handlePermissionAction(id: String) {
        let pane: String
        switch id {
        case Self.accessibility: pane = "Privacy_Accessibility"
        case Self.inputMonitoring: pane = "Privacy_ListenEvent"
        default: return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func activate(context: PluginRuntimeContext) {
        active = true
        refresh()
    }

    func deactivate(reason: PluginDeactivationReason) {
        active = false
        observePermissionChanges(false)
        appPicker?.cancel(nil)
        session.stop()
        feedback.hide()
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        activity = state
        refresh()
    }

    func refreshAccessibilityPermission() { refresh() }

    func physicalInputCompatibilityDidChange(isCompatible: Bool) -> Bool {
        guard hasCompatibleInputPlugins != isCompatible else { return false }
        hasCompatibleInputPlugins = isCompatible
        updateSession()
        return true
    }

    func refresh() {
        updateSession()
        onStateChange?()
    }

    private func updateSession() {
        let wantsProtection = active && activity == .interactive && settings.protectionEnabled && hasQuitScope
            && hasCompatibleInputPlugins
        if !active || activity != .interactive {
            session.stop()
        } else {
            let canRun = wantsProtection && QuitProtectionSession.hasRequiredPermissions
            session.update(quit: settings.quit, enabled: canRun, showsFeedback: settings.showsFeedback)
        }
        observePermissionChanges(wantsProtection)
    }

    private func observePermissionChanges(_ shouldObserve: Bool) {
        let center = NSWorkspace.shared.notificationCenter
        if shouldObserve, permissionObserver == nil {
            // Input Monitoring can change independently of the AX trust observer.
            // Recheck when the user leaves System Settings or activates another app.
            permissionObserver = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.isProtecting != QuitProtectionSession.hasRequiredPermissions else { return }
                    self.refresh()
                }
            }
        } else if !shouldObserve, let permissionObserver {
            center.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(sections: [
            PluginSettingsSection(id: "master", rows: [
                PluginSettingsRow(id: "master.enabled", title: text("Enable Protection"),
                                  description: protectionStatus,
                                  control: .toggle(isOn: settings.protectionEnabled))
            ]),
            confirmationSection,
            scopeSection
        ])
    }

    private var hasQuitScope: Bool {
        if case .extraModifier = settings.quit.confirmation { return false }
        return settings.quit.scope != .selected || !settings.quit.selectedApps.isEmpty
    }

    private var scopeSection: PluginSettingsSection {
        let rule = settings.quit
        let scopeOptions = [
            PluginSettingsOption(id: "all", title: text("All Apps")),
            PluginSettingsOption(id: "selected", title: text("Selected Apps")),
            PluginSettingsOption(id: "allExcept", title: text("All Apps Except"))
        ]
        var rows = [
            PluginSettingsRow(id: "quit.scope", title: text("App Scope"),
                              control: .picker(selectionID: rule.scope.rawValue, options: scopeOptions, style: .menu))
        ]
        if rule.scope != .all {
            let list = rule.scope == .selected ? rule.selectedApps : rule.excludedApps
            let description = list.isEmpty
                ? text(rule.scope == .selected ? "No apps selected" : "No exclusions")
                : nil
            rows.append(PluginSettingsRow(
                id: "quit.add", title: text(rule.scope == .selected ? "Protected Apps" : "Excluded Apps"),
                description: description, control: .action(title: text("Add Apps…"), role: .normal)
            ))
            for identifier in list.sorted() {
                let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                let name = app?.deletingPathExtension().lastPathComponent ?? identifier
                rows.append(PluginSettingsRow(id: "quit.remove." + identifier, title: name,
                                              control: .action(title: text("Remove"), role: .destructive)))
            }
        }
        return PluginSettingsSection(
            id: "scope", footer: text("App switchers and forwarded shortcuts keep their normal behavior."), rows: rows
        )
    }

    private var confirmationSection: PluginSettingsSection {
        let modes = [
            PluginSettingsOption(id: "hold", title: text("Hold to Confirm")),
            PluginSettingsOption(id: "double", title: text("Double Press"))
        ]
        let modeID: String
        let duration: Duration
        switch settings.quit.confirmation {
        case let .hold(value): modeID = "hold"; duration = value
        case let .doublePress(value): modeID = "double"; duration = value
        case .extraModifier: modeID = "hold"; duration = .milliseconds(800)
        }
        var rows = [
            PluginSettingsRow(id: "quit.mode", title: text("Confirm With"),
                              control: .picker(selectionID: modeID, options: modes, style: .menu))
        ]
        rows.append(PluginSettingsRow(
            id: "quit.duration", title: text(modeID == "hold" ? "Hold Duration" : "Time Between Presses"),
            control: .slider(value: duration / .seconds(1), range: 0.5...2, step: 0.1,
                             valueFormat: PluginSettingsSliderValueFormat(suffix: " s", fractionDigits: 1))
        ))
        rows.append(PluginSettingsRow(id: "feedback.enabled", title: text("Show Confirmation Feedback"),
                                      control: .toggle(isOn: settings.showsFeedback)))
        return PluginSettingsSection(id: "quit", title: text("Quit App (⌘Q)"), rows: rows)
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean("master.enabled", enabled): settings.protectionEnabled = enabled
        case let .setBoolean("feedback.enabled", enabled): settings.showsFeedback = enabled; feedback.hide()
        default:
            var rule = settings.quit
            switch action {
            case let .setSelection("quit.scope", selection):
                guard let scope = QuitProtectionRule.AppScope(rawValue: selection) else { return }
                rule.scope = scope
            case let .setSelection("quit.mode", selection):
                switch selection {
                case "hold": rule.confirmation = .hold(.milliseconds(800))
                case "double": rule.confirmation = .doublePress(.milliseconds(600))
                default: return
                }
            case let .setNumber("quit.duration", seconds, .committed):
                guard seconds.isFinite, (0.5...2).contains(seconds) else { return }
                let duration = Duration.milliseconds(Int((seconds * 1_000).rounded()))
                switch rule.confirmation {
                case .hold: rule.confirmation = .hold(duration)
                case .doublePress: rule.confirmation = .doublePress(duration)
                case .extraModifier: return
                }
            case .invoke("quit.add"): chooseApps(); return
            case let .invoke(id) where id.hasPrefix("quit.remove."):
                let identifier = String(id.dropFirst("quit.remove.".count))
                if rule.scope == .selected {
                    rule.selectedApps.remove(identifier)
                } else if rule.scope == .allExcept {
                    rule.excludedApps.remove(identifier)
                }
            default: return
            }
            settings.quit = rule
        }
        save()
    }

    private func chooseApps() {
        guard appPicker == nil, settings.quit.scope != .all else { return }
        let scope = settings.quit.scope
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        appPicker = panel
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel else { return }
            self.appPicker = nil
            guard self.active, response == .OK else { return }
            let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            if scope == .selected {
                self.settings.quit.selectedApps.formUnion(identifiers)
            } else {
                self.settings.quit.excludedApps.formUnion(identifiers)
            }
            self.save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { storage.set(data, forKey: Self.storageKey) }
        refresh()
    }

    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }
}
