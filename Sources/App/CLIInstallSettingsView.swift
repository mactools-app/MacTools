import AppKit
import MacToolsPluginKit
import SwiftUI

struct CLIInstallSettingsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @ObservedObject private var installer: CLIInstallController
    @State private var showingConfirmation = false
    @State private var enableIntegration = true

    @ObservedObject private var service: CLIBrokerServiceController

    init(installer: CLIInstallController = .shared, service: CLIBrokerServiceController = .shared) {
        self.installer = installer
        self.service = service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            header
            if installer.receipt != nil || service.isRegistered {
                integrationToggle
            }
            attention
            DisclosureGroup(CLIInstallCopy.details.text) {
                details
                    .padding(.top, PluginSettingsTheme.Spacing.rowTitleDescription)
            }
            .disclosureGroupStyle(CLISettingsDisclosureStyle())
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .onAppear {
            installer.start()
            service.refresh()
        }
        .sheet(isPresented: $showingConfirmation) {
            confirmation
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
        }
    }

    private var header: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Label(AppL10n.settings("commandLine.title", defaultValue: "MacTools 命令行"), systemImage: "terminal")
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if installer.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(status)
            } else if installer.receipt == nil {
                Button(CLIInstallCopy.installPrompt.text) {
                    enableIntegration = true
                    showingConfirmation = true
                }
                .disabled(installer.manifest == nil)
            } else if installer.phase == .updateAvailable {
                Button(CLIInstallCopy.update.text) {
                    installer.install()
                }
            }
            if installer.receipt != nil {
                Menu(CLIInstallCopy.manage.text) {
                    if installer.canRollback {
                        Button(CLIInstallCopy.rollback.text) {
                            installer.install(rollback: true)
                        }
                    }
                    Button(CLIInstallCopy.remove.text, role: .destructive) { installer.remove() }
                }
                .fixedSize()
                .disabled(installer.busy)
            }
        }
    }

    private var summary: String {
        if installer.busy { return status }
        if case .failed = installer.phase {
            return installer.receipt.map { "\(CLIInstallCopy.installed.text) · v\($0.manifest.cliVersion)" }
                ?? CLIInstallCopy.notInstalled.text
        }
        return installer.receipt.map { "\(status) · v\($0.manifest.cliVersion)" } ?? status
    }

    private var integrationToggle: some View {
        Toggle(isOn: Binding(
            get: { service.isRegistered },
            set: { enabled in
                if enabled { _ = service.ensureRegistered() }
                else { _ = service.unregister() }
            }
        )) {
            Text(CLIInstallCopy.allowConnection.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(installer.busy)
    }

    @ViewBuilder
    private var attention: some View {
        if service.status == .requiresApproval {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(AppL10n.settings("commandLine.requiresApproval",
                    defaultValue: "请在系统设置中允许 MacTools 命令行代理后台运行。"))
                    .foregroundStyle(.secondary)
                Button(AppL10n.settings("commandLine.approve", defaultValue: "允许后台运行")) {
                    service.openApprovalSettings()
                }
            }
        }
        if let error = service.lastError {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
        }
        if case .failed = installer.phase {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(status).foregroundStyle(.orange).textSelection(.enabled)
                HStack {
                    Button(CLIInstallCopy.retry.text) { installer.retry() }
                        .disabled(installer.busy)
                    Button(CLIInstallCopy.copyDiagnostics.text) {
                        copy([status,
                              "App/target: \(installer.manifest?.appVersion ?? "unknown") (\(installer.manifest?.appBuild ?? "unknown"))",
                              "Installed: \(installer.receipt?.manifest.cliBuild ?? "none")",
                              "Rollback held for: \(installer.rollbackForRelease ?? "none")",
                              "Command: \(installer.store?.command.path ?? "unavailable")",
                              "Broker: \(service.status.rawValue)"].joined(separator: "\n"))
                    }
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if let receipt = installer.receipt {
                Text(installer.isRollbackHeld ? CLIInstallCopy.rollbackHelp.text : CLIInstallCopy.automaticUpdates.text)
                    .foregroundStyle(.secondary)
                Text(CLIInstallCopy.build.format(receipt.manifest.cliBuild))
                    .foregroundStyle(.secondary)
                Text(CLIInstallCopy.paths.format(
                    URL(fileURLWithPath: receipt.managedPath).deletingLastPathComponent().path,
                    receipt.linkPath))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(CLIInstallCopy.copyPath.text) { copy(receipt.linkPath) }
                    Button(CLIInstallCopy.reveal.text) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.managedPath)])
                    }
                }
            } else if !service.isRegistered {
                // Manually installed CLIs can connect without a managed receipt.
                integrationToggle
            }
            DisclosureGroup(CLIInstallCopy.terminalSetup.text) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(CLIInstallCopy.pathHelp.text)
                        .foregroundStyle(.secondary)
                    Text("export PATH=\"$HOME/.local/bin:$PATH\"")
                        .textSelection(.enabled)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(CLIInstallCopy.copy.text) { copy("export PATH=\"$HOME/.local/bin:$PATH\"") }
                }
                .padding(.top, PluginSettingsTheme.Spacing.rowTitleDescription)
            }
            .disclosureGroupStyle(CLISettingsDisclosureStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String { CLIInstallCopy.status(installer.phase, error: installer.lastError) }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(CLIInstallCopy.confirmTitle.text).font(.title2)
            if let manifest = installer.manifest, let store = installer.store {
                Text("\(manifest.cliVersion) (\(manifest.cliBuild)) · \(ByteCountFormatter.string(fromByteCount: Int64(manifest.size), countStyle: .file))")
                Text(CLIInstallCopy.paths.format(
                    store.root.appendingPathComponent(manifest.directoryName).path, store.command.path))
                    .font(.callout).textSelection(.enabled)
                Text(CLIInstallCopy.ownershipHelp.text)
                Toggle(CLIInstallCopy.enableIntegration.text, isOn: $enableIntegration).toggleStyle(.switch)
                    .disabled(service.isRegistered)
                Text(enableIntegration || service.isRegistered
                    ? CLIInstallCopy.integrationOn.text
                    : CLIInstallCopy.integrationOff.text)
                    .font(.callout).foregroundStyle(.secondary)
                Text(CLIInstallCopy.automaticUpdates.text)
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(CLIInstallCopy.cancel.text) { showingConfirmation = false }.keyboardShortcut(.cancelAction)
                    Button(CLIInstallCopy.install.text) {
                        showingConfirmation = false
                        installer.install(enableIntegration: enableIntegration)
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 540)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Only the header toggles expansion; controls and selectable text in the content stay independent.
struct CLISettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(configuration.isExpanded
                ? AppL10n.settings("plugins.configuration.disclosure.expanded", defaultValue: "已展开")
                : AppL10n.settings("plugins.configuration.disclosure.collapsed", defaultValue: "已折叠")))
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
