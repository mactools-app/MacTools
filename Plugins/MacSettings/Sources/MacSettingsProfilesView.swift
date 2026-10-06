import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct MacSettingsHistoryView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacSettingsSectionHeader(title: MacSettingsStrings.text("Change History"), description: MacSettingsStrings.text("Only local changes made through MacTools are recorded.")) {
                Button(MacSettingsStrings.text("Clear History")) {
                    showsClearConfirmation = true
                }
                    .disabled(controller.history.isEmpty)
            }
            Divider()
            if controller.history.isEmpty {
                ContentUnavailableView(MacSettingsStrings.text("No Changes Yet"), systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.history) { change in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.settingTitle)
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Text("\(valueDescription(change.previousValue, settingID: change.settingID)) → \(valueDescription(change.newValue, settingID: change.settingID))")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(change.date, format: .dateTime.year().month().day().hour().minute())
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(change.verification == .verified ? MacSettingsStrings.text("Verified") : MacSettingsStrings.text("Unverified"))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(change.verification == .verified ? .green : .orange)
                        if change.canRollback {
                            Button(MacSettingsStrings.text("Restore Previous Value")) { controller.rollback(change) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .alert(MacSettingsStrings.text("Clear Change History?"), isPresented: $showsClearConfirmation) {
            Button(MacSettingsStrings.text("Clear History"), role: .destructive, action: controller.clearHistory)
            Button(MacSettingsStrings.text("Cancel"), role: .cancel) {}
        } message: {
            Text(MacSettingsStrings.format(
                "This removes %@ recorded changes. This cannot be undone.",
                "\(controller.history.count)"
            ))
        }
    }

    private func valueDescription(
        _ value: SystemSettingValue,
        settingID: SystemSettingID
    ) -> String {
        controller.catalog[settingID]?.definition.displayDescription(for: value)
            ?? value.conciseDescription
    }
}

struct MacSettingsProfilesView: View {
    @ObservedObject var controller: MacSettingsController
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @State private var editorTarget: MacSettingsProfileEditorTarget?
    @State private var profilePendingDeletion: SystemSettingsProfile?
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var exportDocument = MacSettingsProfileDocument(data: Data())
    @State private var exportFilename = "Mac Settings.mactoolsprofile"
    @State private var transferAlert: MacSettingsProfileTransferAlert?
    @State private var savedImportedProfileID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let plan = controller.activePlan {
                profilePlanHeader(plan)
            } else {
                MacSettingsSectionHeader(title: MacSettingsStrings.text("Profiles"), description: MacSettingsStrings.text("Save a group of desired settings and choose which ones to apply.")) {
                    Button(MacSettingsStrings.text("Import Profile…"), action: beginImport)
                        .buttonStyle(.bordered)
                    Button(MacSettingsStrings.text("Create Profile"), action: createProfile)
                        .buttonStyle(.borderedProminent)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    if let plan = controller.activePlan {
                        MacSettingsProfilePlanView(controller: controller, plan: plan)
                    } else {
                        if let preview = controller.importedPreview {
                            MacSettingsImportedProfilePreview(
                                preview: preview,
                                isSaved: savedImportedProfileID == preview.profile.id,
                                onSave: { saveImportedProfile(preview.profile) },
                                onCompare: { controller.preparePlan(for: preview.profile) }
                            )
                        }
                        if !controller.builtInTemplates.isEmpty {
                            profileSection(MacSettingsStrings.text("Built-in Templates"), image: "sparkles", profiles: controller.builtInTemplates, isTemplate: true)
                        }
                        profileSection(MacSettingsStrings.text("My Profiles"), image: "square.stack.3d.up", profiles: controller.profiles, isTemplate: false)
                    }
                }
                .padding(18)
            }
        }
        .sheet(item: $editorTarget) { target in
            MacSettingsProfileEditorContainer(
                controller: controller,
                profile: target.profile
            )
            .frame(minWidth: 720, minHeight: 600)
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
        }
        .alert(
            MacSettingsStrings.text("Delete Profile?"),
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            presenting: profilePendingDeletion
        ) { profile in
            Button(MacSettingsStrings.text("Delete Profile"), role: .destructive) {
                controller.removeProfile(profile)
                profilePendingDeletion = nil
            }
            Button(MacSettingsStrings.text("Cancel"), role: .cancel) {
                profilePendingDeletion = nil
            }
        } message: { profile in
            Text(MacSettingsStrings.format("Delete “%@”? This cannot be undone.", "\(profile.name)"))
        }
        .alert(item: $transferAlert) { alert in
            Alert(
                title: Text(MacSettingsStrings.text("Profile Transfer Failed")),
                message: Text(alert.message),
                dismissButton: .default(Text(MacSettingsStrings.text("OK")))
            )
        }
        .fileImporter(
            isPresented: $importsFile,
            allowedContentTypes: [.macToolsSettingsProfile, .json],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .fileExporter(
            isPresented: $exportsFile,
            document: exportDocument,
            contentType: .macToolsSettingsProfile,
            defaultFilename: exportFilename,
            onCompletion: handleExportResult
        )
    }

    private func profilePlanHeader(_ plan: SystemSettingsProfileApplyPlan) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: controller.dismissActivePlan) {
                Label(MacSettingsStrings.text("Profiles"), systemImage: "chevron.backward")
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(controller.isApplyingProfile || controller.isPreparingPlan)
            .accessibilityLabel(MacSettingsStrings.text("Back to Profiles"))
            .accessibilityIdentifier("mac-settings.profiles.back")

            Divider()
                .frame(height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(MacSettingsStrings.format("Compare & Apply · %@", "\(plan.profileName)"))
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Text(MacSettingsStrings.text("Review current and desired values before applying changes."))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func createProfile() {
        editorTarget = .init(profile: nil)
    }

    private func beginImport() {
        controller.clearProfileError()
        transferAlert = nil
        savedImportedProfileID = nil
        importsFile = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else {
            if case let .failure(error) = result, !isUserCancellation(error) {
                showTransferError(error.localizedDescription)
            }
            return
        }
        guard let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await SystemSettingsProfileFileReader.read(
                    from: url,
                    maximumFileSize: SystemSettingsProfileCodec.maximumFileSize
                )
                controller.importProfile(data: data)
                if let message = controller.profileErrorMessage {
                    transferAlert = .init(message: message)
                }
            } catch {
                controller.reportProfileImportFailure(error)
                showTransferError(controller.profileErrorMessage ?? error.localizedDescription)
            }
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        if case let .failure(error) = result, !isUserCancellation(error) {
            showTransferError(MacSettingsStrings.format(
                "Could not export the profile: %@",
                "\(error.localizedDescription)"
            ))
        }
    }

    private func saveImportedProfile(_ profile: SystemSettingsProfile) {
        guard controller.acceptImportedProfile() else {
            if let message = controller.profileErrorMessage {
                transferAlert = .init(message: message)
            }
            return
        }
        savedImportedProfileID = profile.id
    }

    private func beginExport(_ profile: SystemSettingsProfile) {
        do {
            exportDocument = MacSettingsProfileDocument(data: try controller.exportData(for: profile))
            exportFilename = MacSettingsProfileFilename.exportName(for: profile.name)
            DispatchQueue.main.async { exportsFile = true }
        } catch {
            showTransferError(MacSettingsStrings.format(
                "Could not export the profile: %@",
                "\(error.localizedDescription)"
            ))
        }
    }

    private func showTransferError(_ message: String) {
        transferAlert = .init(message: message)
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError
    }

    private func profileSection(
        _ title: String,
        image: String,
        profiles: [SystemSettingsProfile],
        isTemplate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(title, systemImage: image)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            if profiles.isEmpty {
                Text(MacSettingsStrings.text("No Profiles Yet"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsCardBackground(.standard)
            } else {
                VStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(PluginSettingsTheme.Typography.rowTitle)
                                Text(profile.profileDescription.isEmpty ? MacSettingsStrings.format("Settings: %@", "\(profile.entries.count)") : profile.profileDescription)
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(MacSettingsStrings.format("Items: %@", "\(profile.entries.count)"))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.secondary)
                            Button(MacSettingsStrings.text("Preview & Apply")) { controller.preparePlan(for: profile) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            if isTemplate {
                                Button(MacSettingsStrings.text("Save a Copy")) { controller.saveTemplate(profile) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Menu {
                                    Button(MacSettingsStrings.text("Export…")) {
                                        beginExport(profile)
                                    }
                                    Divider()
                                    Button(MacSettingsStrings.text("Edit")) {
                                        editorTarget = .init(profile: profile)
                                    }
                                    Button(MacSettingsStrings.text("Delete"), role: .destructive) {
                                        profilePendingDeletion = profile
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 28)
                            }
                        }
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                        if profile.id != profiles.last?.id { Divider() }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }
        }
    }
}

private struct MacSettingsProfileEditorTarget: Identifiable {
    let id = UUID()
    let profile: SystemSettingsProfile?
}

private struct MacSettingsProfileTransferAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct MacSettingsImportedProfilePreview: View {
    let preview: SystemSettingsImportPreview
    let isSaved: Bool
    let onSave: () -> Void
    let onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(MacSettingsStrings.text("Import Preview"), systemImage: "doc.text.magnifyingglass")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.profile.name)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(preview.profile.profileDescription.isEmpty
                         ? MacSettingsStrings.format("Settings: %@", "\(preview.profile.entries.count)")
                         : preview.profile.profileDescription)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !preview.validation.warnings.isEmpty {
                        Text(MacSettingsStrings.format(
                            "Unknown settings: %@. They will be preserved but never applied.",
                            "\(preview.validation.warnings.count)"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 16)
                Button(
                    isSaved ? MacSettingsStrings.text("Saved") : MacSettingsStrings.text("Save to My Profiles"),
                    action: onSave
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSaved)
                Button(MacSettingsStrings.text("Compare & Apply"), action: onCompare)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            .pluginSettingsCardBackground(.standard)
        }
    }
}

private struct MacSettingsProfileEditorContainer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: MacSettingsController
    let profile: SystemSettingsProfile?
    @State private var draft: SystemSettingsProfileDraft?

    var body: some View {
        ZStack {
            if let draft {
                MacSettingsProfileEditorView(
                    controller: controller,
                    initialDraft: draft,
                    profile: profile,
                    onCancel: { dismiss() },
                    onSave: save
                )
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(MacSettingsStrings.text("Preparing Profile…"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("mac-settings.profile-editor.loading")
            }
        }
        .task(prepareDraft)
    }

    private func prepareDraft() async {
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        draft = controller.makeDraft(from: profile)
    }

    private func save(_ draft: SystemSettingsProfileDraft) {
        if controller.saveDraft(draft, replacing: profile) {
            dismiss()
        }
    }
}

private struct MacSettingsProfileEditorView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var draft: SystemSettingsProfileDraft
    @State private var searchText = ""
    let profile: SystemSettingsProfile?
    let onCancel: () -> Void
    let onSave: (SystemSettingsProfileDraft) -> Void

    private var visibleRecords: [SystemSettingRecord] {
        controller.catalog.search(searchText).filter(\.definition.isProfileEligible)
    }

    private var visibleCategories: [SystemSettingCategory] {
        let categories = Set(visibleRecords.map(\.definition.category))
        return controller.availableCategories.filter(categories.contains)
    }

    private var selectedCount: Int {
        draft.items.filter(\.isIncluded).count
    }

    private var validationMessage: String? {
        controller.draftValidationMessage(draft, replacing: profile)
    }

    private var status: MacSettingsProfileEditorStatus {
        if let message = controller.profileErrorMessage {
            return .init(message: message, systemImage: "exclamationmark.triangle.fill", color: .red)
        }
        if let validationMessage {
            return .init(message: validationMessage, systemImage: "info.circle.fill", color: .orange)
        }
        return .init(
            message: MacSettingsStrings.format("Ready to save %@ settings.", "\(selectedCount)"),
            systemImage: "checkmark.circle.fill",
            color: .green
        )
    }

    init(
        controller: MacSettingsController,
        initialDraft: SystemSettingsProfileDraft,
        profile: SystemSettingsProfile?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SystemSettingsProfileDraft) -> Void
    ) {
        self.controller = controller
        _draft = State(initialValue: initialDraft)
        self.profile = profile
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile == nil ? MacSettingsStrings.text("Create Profile") : MacSettingsStrings.text("Edit Profile"))
                        .font(PluginSettingsTheme.Typography.pageTitle)
                    Text(MacSettingsStrings.text("Select a setting to include it in this profile. Off is still an explicit desired value."))
                        .font(PluginSettingsTheme.Typography.pageDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(MacSettingsStrings.text("Cancel"), action: onCancel)
                Button(MacSettingsStrings.text("Save")) { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(validationMessage != nil)
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(status.message, systemImage: status.systemImage)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(status.color)
                        .lineLimit(2)
                        .help(status.message)
                        .frame(maxWidth: .infinity, minHeight: 38, idealHeight: 38, maxHeight: 38, alignment: .leading)
                        .accessibilityIdentifier("mac-settings.profile-editor.status")
                    TextField(MacSettingsStrings.text("Profile Name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                    TextField(MacSettingsStrings.text("Description (Optional)"), text: $draft.profileDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 4)

                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField(MacSettingsStrings.text("Search Profile Settings"), text: $searchText)
                                .textFieldStyle(.plain)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(MacSettingsStrings.text("Clear Search"))
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            PluginSettingsTheme.Palette.fieldBackground,
                            in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                                .strokeBorder(PluginSettingsTheme.Palette.separator, lineWidth: PluginSettingsTheme.Stroke.hairline)
                                .allowsHitTesting(false)
                        }

                        Text(MacSettingsStrings.format("%@ selected", "\(selectedCount)"))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }

                    if visibleRecords.isEmpty {
                        ContentUnavailableView(
                            MacSettingsStrings.text("No Profile Settings Found"),
                            systemImage: "magnifyingglass",
                            description: Text(MacSettingsStrings.text("Try another setting name or keyword."))
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }

                    ForEach(visibleCategories) { category in
                        let categoryRecords = visibleRecords.filter {
                            $0.definition.category == category
                        }
                        if !categoryRecords.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(category.title, systemImage: category.systemImage)
                                        .font(PluginSettingsTheme.Typography.sectionTitle)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(MacSettingsStrings.text("Select All")) {
                                        setIncluded(true, for: categoryRecords)
                                    }
                                        .buttonStyle(.link)
                                    Button(MacSettingsStrings.text("Deselect All")) {
                                        setIncluded(false, for: categoryRecords)
                                    }
                                        .buttonStyle(.link)
                                }

                                VStack(spacing: 0) {
                                    ForEach(categoryRecords, id: \.id) { record in
                                        if let index = draft.items.firstIndex(where: { $0.settingID == record.id }) {
                                            HStack(spacing: 12) {
                                                MacSettingsSelectionButton(
                                                    isSelected: draft.items[index].isIncluded,
                                                    accessibilityLabel: MacSettingsStrings.format(
                                                        "Include %@ in this profile",
                                                        "\(record.definition.title)"
                                                    ),
                                                    onToggle: {
                                                        draft.items[index].isIncluded.toggle()
                                                    }
                                                )
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(record.definition.title)
                                                        .font(PluginSettingsTheme.Typography.rowTitle)
                                                    Text(MacSettingsStrings.format("Current: %@", "\(controller.rowStates[record.id]?.value.map(record.definition.displayDescription(for:)) ?? MacSettingsStrings.text("Unknown"))"))
                                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                SystemSettingValueControl(
                                                    schema: profileSchema(for: record.definition.schema),
                                                    value: draft.items[index].desiredValue,
                                                    enabled: true,
                                                    compact: true,
                                                    usesSegmentedPicker: record.id == "appearance.dark-mode",
                                                    onChange: { draft.setDesiredValue($0, for: record.id); return true }
                                                )
                                                .accessibilityLabel(MacSettingsStrings.format("Desired value for %@", "\(record.definition.title)"))
                                                .accessibilityValue(record.definition.displayDescription(for: draft.items[index].desiredValue))
                                            }
                                            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                                            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                                            if record.id != categoryRecords.last?.id { Divider() }
                                        }
                                    }
                                }
                                .pluginSettingsCardBackground(.standard)
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .onAppear { controller.clearProfileError() }
        .onChange(of: draft) { controller.clearProfileError() }
    }

    private func profileSchema(for schema: SystemSettingValueSchema) -> SystemSettingValueSchema {
        if case let .directoryChoice(options) = schema { return .choice(options: options) }
        return schema
    }

    private func setIncluded(_ isIncluded: Bool, for records: [SystemSettingRecord]) {
        for record in records {
            draft.setIncluded(isIncluded, for: record.id)
        }
    }
}

private struct MacSettingsProfileEditorStatus {
    let message: String
    let systemImage: String
    let color: Color
}

private struct MacSettingsProfilePlanView: View {
    @ObservedObject var controller: MacSettingsController
    let plan: SystemSettingsProfileApplyPlan

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                let selectedCount = plan.items.filter(\.isSelected).count
                Label(
                    MacSettingsStrings.format("%@ selected", "\(selectedCount)"),
                    systemImage: selectedCount > 0 ? "checkmark.square.fill" : "square"
                )
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(selectedCount > 0 ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(selectedCount > 0 ? 0.1 : 0), in: Capsule())
                Spacer()
                Button(MacSettingsStrings.text("Apply Selected Changes")) { controller.applyActivePlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canEditSettings || controller.lastApplyReport?.planID == plan.id
                              || !plan.items.contains(where: { $0.isSelected }))
            }

            MacSettingsProfilePlanTable(
                controller: controller,
                plan: plan,
                valueDescription: valueDescription,
                statusDescription: { progressText(for: $0) ?? planStatusText($0.status) }
            )
            .pluginSettingsCardBackground(.standard)

            if let report = controller.lastApplyReport {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(resultTitle(report))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Spacer()
                        if controller.canRetryFailedChanges {
                            Button(MacSettingsStrings.text("Retry Unfinished Items…")) { controller.retryFailedChanges() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        if !report.rollbackPoint.entries.isEmpty,
                           controller.lastRollbackResults?.allSatisfy({ [.appliedAndVerified, .skippedByUser].contains($0.kind) }) != true {
                            Button(MacSettingsStrings.text("Undo Applied Items")) { controller.rollbackLastApply() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(controller.isApplyingProfile || controller.isPreparingPlan)
                        }
                    }
                    ForEach(controller.lastRollbackResults ?? report.results) { result in
                        HStack {
                            Text(result.title)
                            Spacer()
                            Text(controller.lastRollbackResults != nil && result.kind == .appliedAndVerified
                                 ? MacSettingsStrings.text("Restored and Verified") : applyResultText(result.kind))
                                .foregroundStyle(result.kind == .appliedAndVerified ? .green : .secondary)
                            if let message = result.message {
                                Text(message).foregroundStyle(.red).lineLimit(1)
                            }
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                }
                .padding()
                .pluginSettingsCardBackground(.recessed)
            }
        }
    }

    private func valueDescription(
        _ value: SystemSettingValue?,
        settingID: SystemSettingID
    ) -> String {
        guard let value else { return MacSettingsStrings.text("Unknown") }
        return controller.catalog[settingID]?.definition.displayDescription(for: value)
            ?? value.conciseDescription
    }

    private func planStatusText(_ status: SystemSettingsProfilePlanStatus) -> String {
        switch status {
        case .ready: MacSettingsStrings.text("Ready to Apply")
        case .alreadyMatches: MacSettingsStrings.text("Already Matches")
        case .requiresLogout: MacSettingsStrings.text("Log Out and Back In Required")
        case .requiresRestart: MacSettingsStrings.text("Reopen Related App")
        case .guidedManual: MacSettingsStrings.text("Manual Step")
        case .unsupported: MacSettingsStrings.text("Unsupported")
        case .unavailable: MacSettingsStrings.text("Unavailable")
        case .verificationUnavailable: MacSettingsStrings.text("Cannot Verify")
        case .invalidValue: MacSettingsStrings.text("Invalid Value")
        case .unknownSetting: MacSettingsStrings.text("Unknown Setting")
        }
    }

    private func resultTitle(_ report: SystemSettingsProfileApplyReport) -> String {
        if let results = controller.lastRollbackResults {
            if results.allSatisfy({ $0.kind == .appliedAndVerified }) { return MacSettingsStrings.text("Rolled Back") }
            return results.allSatisfy { [.appliedAndVerified, .skippedByUser].contains($0.kind) }
                ? MacSettingsStrings.text("Recovery Resolved") : MacSettingsStrings.text("Rollback Incomplete")
        }
        if !report.hasPartialSuccess { return MacSettingsStrings.text("Completed") }
        return report.results.contains { [.appliedAndVerified, .pendingRestart, .pendingLogout, .alreadyMatched].contains($0.kind) }
            ? MacSettingsStrings.text("Partially Completed") : MacSettingsStrings.text("Not Completed")
    }

    private func progressText(for item: SystemSettingsProfilePlanItem) -> String? {
        if controller.isApplyingProfile, let progress = controller.operationProgress {
            if progress.activeSettingID == item.settingID { return progress.phase?.title }
            if let result = progress.results.first(where: { $0.settingID == item.settingID }) {
                if controller.operationState == .restoring, result.kind == .appliedAndVerified { return MacSettingsStrings.text("Restored and Verified") }
                return applyResultText(result.kind)
            }
            return item.isSelected ? MacSettingsStrings.text("Waiting") : nil
        }
        if let result = controller.lastRollbackResults?.first(where: { $0.settingID == item.settingID }) {
            return result.kind == .appliedAndVerified ? MacSettingsStrings.text("Restored and Verified") : applyResultText(result.kind)
        }
        return controller.lastApplyReport?.results.first { $0.settingID == item.settingID }.map { applyResultText($0.kind) }
    }

    private func applyResultText(_ result: SystemSettingsProfileApplyResultKind) -> String {
        switch result {
        case .appliedAndVerified: MacSettingsStrings.text("Applied and Verified")
        case .alreadyMatched: MacSettingsStrings.text("Already Matches")
        case .pendingLogout: MacSettingsStrings.text("Applied; Log Out and Back In")
        case .pendingRestart: MacSettingsStrings.text("Applied; Reopen Related App")
        case .skippedByUser: MacSettingsStrings.text("Skipped")
        case .guidedManual: MacSettingsStrings.text("Manual Step")
        case .unsupported: MacSettingsStrings.text("Unsupported")
        case .providerUnavailable: MacSettingsStrings.text("Provider Unavailable")
        case .hardwareUnavailable: MacSettingsStrings.text("Hardware Unavailable")
        case .permissionMissing: MacSettingsStrings.text("Permission Required")
        case .systemVersionUnavailable: MacSettingsStrings.text("Unsupported macOS Version")
        case .failedAndRolledBack: MacSettingsStrings.text("Failed and Rolled Back")
        case .failedWithoutRollback: MacSettingsStrings.text("Failed; Rollback Unsuccessful")
        case .verificationUnavailable: MacSettingsStrings.text("Applied but Could Not Verify")
        case .previewChanged: MacSettingsStrings.text("Current Value Changed; Preview Again")
        case .cancelled: MacSettingsStrings.text("Cancelled")
        }
    }
}

private struct MacSettingsProfilePlanTable: View {
    @ObservedObject var controller: MacSettingsController
    let plan: SystemSettingsProfileApplyPlan
    let valueDescription: (SystemSettingValue?, SystemSettingID) -> String
    let statusDescription: (SystemSettingsProfilePlanItem) -> String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideTable
                .frame(minWidth: 660)
            compactTable
        }
    }

    private var wideTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 22, height: 1).accessibilityHidden(true)
                Text(MacSettingsStrings.text("Setting"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(MacSettingsStrings.text("Current"))
                    .frame(width: 110, alignment: .trailing)
                Color.clear.frame(width: 14, height: 1).accessibilityHidden(true)
                Text(MacSettingsStrings.text("Desired"))
                    .frame(width: 110, alignment: .leading)
                Text(MacSettingsStrings.text("Status"))
                    .frame(width: 140, alignment: .leading)
            }
            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            .foregroundStyle(.secondary)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, 8)

            Divider()

            ForEach(plan.items) { item in
                selectableRow(for: item) {
                    HStack(spacing: 10) {
                        selectionIndicator(for: item)
                        Text(item.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(valueDescription(item.currentValue, item.settingID))
                            .frame(width: 110, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.forward")
                            .frame(width: 14)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(valueDescription(item.desiredValue, item.settingID))
                            .frame(width: 110, alignment: .leading)
                        status(for: item)
                            .frame(width: 140, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                }
                if item.id != plan.items.last?.id { Divider() }
            }
        }
    }

    private var compactTable: some View {
        VStack(spacing: 0) {
            ForEach(plan.items) { item in
                selectableRow(for: item) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            selectionIndicator(for: item)
                            Text(item.title)
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Spacer()
                            status(for: item)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            valueColumn(
                                title: MacSettingsStrings.text("Current"),
                                value: valueDescription(item.currentValue, item.settingID)
                            )
                            Image(systemName: "arrow.forward")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            valueColumn(
                                title: MacSettingsStrings.text("Desired"),
                                value: valueDescription(item.desiredValue, item.settingID)
                            )
                        }
                        .padding(.leading, 30)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                }
                if item.id != plan.items.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private func selectableRow<Content: View>(
        for item: SystemSettingsProfilePlanItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if item.status.canSelect {
            Button {
                updateSelection(item: item, isSelected: !item.isSelected)
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .disabled(controller.isApplyingProfile)
            .background(item.isSelected ? Color.accentColor.opacity(0.075) : Color.clear)
            .accessibilityLabel(MacSettingsStrings.format("Apply %@", "\(item.title)"))
            .accessibilityValue(
                item.isSelected
                    ? MacSettingsStrings.text("Selected")
                    : MacSettingsStrings.text("Not Selected")
            )
        } else {
            content()
        }
    }

    private func selectionIndicator(for item: SystemSettingsProfilePlanItem) -> some View {
        let appearance = MacSettingsProfileSelectionAppearance(
            status: item.status,
            isSelected: item.isSelected
        )
        let color: Color
        switch appearance {
        case .selected: color = .accentColor
        case .unselected: color = .secondary
        case .alreadyMatches: color = .green
        case .unavailable: color = Color(nsColor: .tertiaryLabelColor)
        }
        return Image(systemName: appearance.systemImage)
            .font(.system(size: 16, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private func status(for item: SystemSettingsProfilePlanItem) -> some View {
        Text(statusDescription(item))
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(statusColor(for: item))
    }

    private func statusColor(for item: SystemSettingsProfilePlanItem) -> Color {
        if item.status == .alreadyMatches { return .green }
        return item.status.canSelect ? .primary : .secondary
    }

    private func valueColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateSelection(
        item: SystemSettingsProfilePlanItem,
        isSelected: Bool
    ) {
        var ids = Set(plan.items.filter(\.isSelected).map(\.settingID))
        if isSelected {
            ids.insert(item.settingID)
        } else {
            ids.remove(item.settingID)
        }
        controller.updatePlanSelection(ids)
    }
}

private struct MacSettingsSelectionButton: View {
    let isSelected: Bool
    let accessibilityLabel: String
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            isSelected
                ? MacSettingsStrings.text("Selected")
                : MacSettingsStrings.text("Not Selected")
        )
    }
}

enum MacSettingsProfileSelectionAppearance: Equatable {
    case selected
    case unselected
    case alreadyMatches
    case unavailable

    init(status: SystemSettingsProfilePlanStatus, isSelected: Bool) {
        if status.canSelect {
            self = isSelected ? .selected : .unselected
        } else if status == .alreadyMatches {
            self = .alreadyMatches
        } else {
            self = .unavailable
        }
    }

    var systemImage: String {
        switch self {
        case .selected: "checkmark.square.fill"
        case .unselected: "square"
        case .alreadyMatches: "checkmark.circle.fill"
        case .unavailable: "minus.circle"
        }
    }
}
