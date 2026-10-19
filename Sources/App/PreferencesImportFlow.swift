import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct PendingPreferencesImport: Identifiable {
    let id = UUID()
    let backup: PreferencesBackup
    let preview: PreferencesImportPreview
}

/// One restore flow for Settings and the first-launch window.
@MainActor
final class PreferencesImportController: ObservableObject {
    let pluginHost: PluginHost
    @Published var pendingImport: PendingPreferencesImport?
    @Published var alertMessage: String?
    @Published private(set) var isPreparingImport = false
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: PreferencesImportProgress?
    private(set) var didImport = false
    var isBusy: Bool { isPreparingImport || isImporting || pendingImport != nil }

    init(pluginHost: PluginHost) { self.pluginHost = pluginHost }

    func choosePreferencesImport() {
        guard !isBusy, pluginHost.preferencesImportUnavailableMessage == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = AppL10n.preferencesBackup("preferencesBackup.import.prompt", defaultValue: "选择 MacTools 导出的偏好设置 JSON 文件。")

        isPreparingImport = true
        PluginPresentationSafety.prepareForWindowOrdering()
        let completion: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else {
                isPreparingImport = false
                return
            }
            prepareImport(from: url)
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func prepareImport(from url: URL) {
        Task { @MainActor in
            defer { isPreparingImport = false }

            do {
                let backup = try await PreferencesBackup.decodeJSON(contentsOf: url)
                await pluginHost.refreshPluginCatalog()
                pendingImport = PendingPreferencesImport(
                    backup: backup,
                    preview: try pluginHost.preferencesImportPreview(for: backup)
                )
            } catch {
                alertMessage = Self.errorMessage(error)
            }
        }
    }

    func importPreferences(
        _ backup: PreferencesBackup,
        installingMissingPluginIDs pluginIDs: Set<String>,
        selection: PreferencesBackupSelection
    ) {
        guard !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            importProgress = .preparing(pluginCount: pluginIDs.count)
            defer {
                isImporting = false
                importProgress = nil
            }

            do {
                let result = try await pluginHost.importPreferences(
                    backup,
                    installingMissingPluginIDs: pluginIDs,
                    selection: selection,
                    progress: { importProgress = $0 }
                )
                pluginHost.starterPacks.finishOnboarding()
                didImport = true
                pendingImport = nil
                let importedMessage = AppL10n.preferencesBackup(
                    "preferencesBackup.imported",
                    defaultValue: "偏好设置已导入。"
                )
                let warnings = result.pluginInstallationFailures
                    .sorted { $0.key < $1.key }
                    .map { pluginID, message in
                        let title = pluginHost.pluginManagementItems
                            .first(where: { $0.id == pluginID })?
                            .title
                            ?? pluginID
                        return "\(title): \(message)"
                    }
                    + result.deferredPluginPreferenceIDs.map { pluginID in
                        let title = pluginHost.pluginManagementItems
                            .first(where: { $0.id == pluginID })?
                            .title
                            ?? pluginID
                        return AppL10n.preferencesBackupFormat(
                            "preferencesBackup.import.pluginRestoreDeferred",
                            defaultValue: "已安装“%@”。请重新启动 MacTools，然后再次导入此备份以恢复其设置。",
                            title
                        )
                    }
                    + result.shortcutErrors
                        .values
                        .sorted()
                alertMessage = warnings.isEmpty
                    ? importedMessage
                    : ([importedMessage] + warnings).joined(separator: "\n")
            } catch {
                pendingImport = nil
                alertMessage = Self.errorMessage(error)
            }
        }
    }

    func pluginOptions(for pluginIDs: Set<String>) -> [PreferencesPluginOption] {
        let titles = Dictionary(
            pluginHost.pluginManagementItems.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        return pluginIDs.map { id in
            PreferencesPluginOption(id: id, title: titles[id] ?? id)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    static func errorMessage(_ error: Error) -> String {
        switch error as? PreferencesBackupError {
        case let .unsupportedFormatVersion(version):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.unsupportedFormat",
                defaultValue: "不支持的偏好设置备份版本（%d）。",
                version
            )
        case .invalidApplicationPreferences:
            return AppL10n.preferencesBackup(
                "preferencesBackup.error.invalidApplicationPreferences",
                defaultValue: "备份中的应用偏好设置无效。"
            )
        case let .fileTooLarge(maximumBytes):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.fileTooLarge",
                defaultValue: "偏好设置备份不能超过 %d MB。",
                maximumBytes / (1024 * 1024)
            )
        case nil:
            return error.localizedDescription
        }
    }
}

struct PreferencesImportPresentation: ViewModifier {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @ObservedObject var controller: PreferencesImportController
    @ObservedObject var host: PluginHost
    @ObservedObject var starterPacks: StarterPackController
    var onCompletion: () -> Void = {}

    func body(content: Content) -> some View {
        content
        .sheet(item: $controller.pendingImport) { pending in
            PreferencesImportPreviewSheet(
                preview: pending.preview,
                previewProvider: { selection in
                    try controller.pluginHost.preferencesImportPreview(
                        for: pending.backup,
                        selection: selection
                    )
                },
                pluginOptions: controller.pluginOptions(for: Set(pending.backup.pluginPreferences.keys)),
                isImporting: controller.isImporting,
                importProgress: controller.importProgress,
                isPreparingPlugins: host.isPreparingPlugins,
                importUnavailableMessage: controller.isImporting ? nil : host.preferencesImportUnavailableMessage,
                catalogStatus: host.pluginCatalogStatus,
                onRetryCatalog: { await controller.pluginHost.refreshPluginCatalog() },
                onCancel: { controller.pendingImport = nil },
                onImport: { selectedPluginIDs, selection in
                    controller.importPreferences(
                        pending.backup,
                        installingMissingPluginIDs: selectedPluginIDs,
                        selection: selection
                    )
                }
            )
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
        .alert(AppL10n.preferencesBackup("preferencesBackup.alert.title", defaultValue: "偏好设置备份"),
               isPresented: Binding(get: { controller.alertMessage != nil }, set: { if !$0 { controller.alertMessage = nil } })) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {
                if controller.didImport { onCompletion() }
            }
        } message: { Text(controller.alertMessage ?? "") }
    }
}
