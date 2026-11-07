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
final class QuitProtectionPlugin: MacToolsPlugin, PluginApplicationActivityStateHandling, AccessibilityPermissionRefreshing {
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
    private var activity: PluginApplicationActivityState = .interactive
    private var appPicker: NSOpenPanel?

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(context: PluginRuntimeContext) {
        storage = context.storage
        localization = PluginLocalization(bundle: context.resourceBundle)
        settings = storage.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        session.showFeedback = { [weak self] app, state in
            guard let self, self.settings.showsFeedback else { return }
            let message: String
            switch state {
            case .holding: message = self.text("Hold ⌘Q to quit")
            case .ready: message = self.text("Release Q to quit")
            case .doublePress: message = self.text("Press ⌘Q again to quit")
            }
            self.feedback.show(for: app, message: message, state: state)
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

    var panelItems: [PluginPanelItem] {
        let subtitle: String
        if !settings.protectionEnabled {
            subtitle = text("Paused")
        } else if !hasQuitScope {
            subtitle = text("Choose apps to protect in Settings")
        } else if !session.isRunning {
            subtitle = text("Protection unavailable")
        } else {
            subtitle = text("Protecting ⌘Q")
        }
        return [
            .row(id: "protection", initialPlacement: .featurePanel,
                 descriptor: PluginPanelRowDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented),
                 state: PluginPanelRowState(subtitle: subtitle, isOn: settings.protectionEnabled, isEnabled: true,
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
        appPicker?.cancel(nil)
        session.stop()
        feedback.hide()
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        activity = state
        refresh()
    }

    func refreshAccessibilityPermission() { refresh() }

    func refresh() {
        if !active || activity != .interactive {
            session.stop()
        } else {
            let canRun = settings.protectionEnabled && hasQuitScope
                && permissionState(for: Self.accessibility).isGranted && permissionState(for: Self.inputMonitoring).isGranted
            session.update(quit: settings.quit, enabled: canRun)
        }
        onStateChange?()
    }

    var settingsPage: PluginSettingsPage? {
        .form(sections: [
            PluginSettingsSection(id: "master", rows: [
                PluginSettingsRow(id: "master.enabled", title: text("Enable Protection"),
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
        return PluginSettingsSection(id: "scope", rows: rows)
    }

    private var confirmationSection: PluginSettingsSection {
        let modes = [
            PluginSettingsOption(id: "hold", title: text("Hold to Confirm")),
            PluginSettingsOption(id: "double", title: text("Double Press"))
        ]
        let modeID: String
        let duration: Duration?
        switch settings.quit.confirmation {
        case let .hold(value): modeID = "hold"; duration = value
        case let .doublePress(value): modeID = "double"; duration = value
        case .extraModifier: modeID = "extra"; duration = nil
        }
        var rows = [
            PluginSettingsRow(id: "quit.mode", title: text("Confirm With"),
                              control: .picker(selectionID: modeID, options: modes, style: .menu))
        ]
        if let duration {
            let components = duration.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            rows.append(PluginSettingsRow(
                id: "quit.duration", title: text(modeID == "hold" ? "Hold Duration" : "Time Between Presses"),
                control: .slider(value: seconds, range: 0.5...2, step: 0.1,
                                                       valueFormat: PluginSettingsSliderValueFormat(suffix: " s", fractionDigits: 1))
            ))
        }
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
