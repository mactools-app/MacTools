import SwiftUI
import MacToolsPluginKit

struct StarterPackOnboardingView: View {
    @ObservedObject var controller: StarterPackController
    @ObservedObject var host: PluginHost
    @ObservedObject var navigation: SettingsNavigationCoordinator
    @ObservedObject var importer: PreferencesImportController
    @ObservedObject private var localization = PluginRuntimeLocalization.source
    let onExit: () -> Void
    let onOpenSettings: (SettingsNavigationDestination) -> Void
    let onOpenPanel: (String) -> Void

    private var step: StarterPackStep {
        if case let .starterPacks(step) = navigation.destination { return step }
        return .choose
    }

    var body: some View {
        StarterPackSettingsView(
            controller: controller, host: host, navigation: navigation, step: step,
            isOnboarding: true, onExit: onExit, onRestore: importer.choosePreferencesImport,
            onOpenSettings: onOpenSettings, onOpenPanel: onOpenPanel
        )
        .id(localization.revision)
        .disabled(importer.isBusy || importer.alertMessage != nil)
        .overlay {
            if importer.isPreparingImport { ProgressView().controlSize(.small) }
        }
        .modifier(PreferencesImportPresentation(controller: importer, host: host, starterPacks: controller, onCompletion: onExit))
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, StandaloneCommandPaletteRootView.layoutDirection(for: PluginRuntimeLocalization.locale))
    }
}
