import AppKit
import SwiftUI
import MacToolsPluginKit

private enum AutomationSplitViewLayout {
    static let workflowListMinWidth: CGFloat = 220
    static let workflowListIdealWidth: CGFloat = 280
    static let workflowListMaxWidth: CGFloat = 340
    static let detailMinWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 8
    static let accessibilityAdjustment: CGFloat = 10

    static func maximumSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        max(
            workflowListMinWidth,
            min(
                workflowListMaxWidth,
                availableWidth - detailMinWidth - dividerWidth
            )
        )
    }

    static func clampedSidebarWidth(_ width: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(width, workflowListMinWidth), maximum)
    }
}

enum WorkflowListReorder {
    static func move(
        sourceOffsets: IndexSet,
        destinationOffset: Int,
        itemCount: Int
    ) -> (sourceIndex: Int, offset: Int)? {
        guard sourceOffsets.count == 1,
              let sourceIndex = sourceOffsets.first,
              (0..<itemCount).contains(sourceIndex),
              (0...itemCount).contains(destinationOffset) else {
            return nil
        }

        let destinationIndex = destinationOffset > sourceIndex
            ? destinationOffset - 1
            : destinationOffset
        let offset = destinationIndex - sourceIndex
        return offset == 0 ? nil : (sourceIndex, offset)
    }
}

private struct WorkflowConditionalAccessibilityActionModifier: ViewModifier {
    let isEnabled: Bool
    let name: String
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

private struct WorkflowKeyboardBoundaryMoveModifier: ViewModifier {
    let canMoveToTop: Bool
    let canMoveToBottom: Bool
    let moveToTop: () -> Void
    let moveToBottom: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard press.modifiers == [.command, .option] else { return .ignored }
            switch press.key {
            case .upArrow where canMoveToTop:
                moveToTop()
                return .handled
            case .downArrow where canMoveToBottom:
                moveToBottom()
                return .handled
            default:
                return .ignored
            }
        }
    }
}

struct AutomationSettingsView: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @ObservedObject private var pluginHost: PluginHost
    @ObservedObject private var automation: AutomationController
    @ObservedObject private var navigationCoordinator: SettingsNavigationCoordinator
    @State private var selectedWorkflowID: UUID?
    @State private var previewRequest: WorkflowPreviewRequest?
    @State private var pendingDeleteWorkflow: WorkflowDefinition?
    @State private var workflowListWidth = AutomationSplitViewLayout.workflowListIdealWidth
    @GestureState private var workflowListDragTranslation: CGFloat = 0
    @AppStorage("automation.previewBeforeRunning") private var previewBeforeRunning = true

    init(
        pluginHost: PluginHost,
        navigationCoordinator: SettingsNavigationCoordinator
    ) {
        self.pluginHost = pluginHost
        self.automation = pluginHost.automationController
        self.navigationCoordinator = navigationCoordinator
    }

    var body: some View {
        GeometryReader { geometry in
            let maximumSidebarWidth = AutomationSplitViewLayout.maximumSidebarWidth(
                for: geometry.size.width
            )
            let sidebarWidth = AutomationSplitViewLayout.clampedSidebarWidth(
                workflowListWidth + directionalTranslation(workflowListDragTranslation),
                maximum: maximumSidebarWidth
            )

            HStack(spacing: 0) {
                workflowList
                    .frame(width: sidebarWidth)

                splitDivider(
                    sidebarWidth: sidebarWidth,
                    maximumSidebarWidth: maximumSidebarWidth
                )

                workflowDetail
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: geometry.size.width) { _, _ in
                workflowListWidth = AutomationSplitViewLayout.clampedSidebarWidth(
                    workflowListWidth,
                    maximum: maximumSidebarWidth
                )
            }
        }
        .overlay(alignment: .top) {
            if let error = automation.definitionLoadErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .padding(PluginSettingsTheme.Spacing.cardContent)
                    .pluginSettingsCardBackground(.standard)
                    .padding(PluginSettingsTheme.Spacing.pagePadding)
            }
        }
        .background(SettingsStyle.contentBackground)
        .sheet(item: $previewRequest) { request in
            if let workflow = automation.workflows.first(where: { $0.id == request.workflowID }) {
                WorkflowRunPreviewSheet(
                    automation: automation,
                    workflow: workflow,
                    onRun: { _ = automation.startWorkflow(id: workflow.id) }
                )
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
            }
        }
        .alert(item: $pendingDeleteWorkflow) { workflow in
            Alert(
                title: Text(FeatureL10n.string("删除工作流？")),
                message: Text(FeatureL10n.string("运行中的任务会先停止，相关自动规则会一并删除。保存的快捷键、运行链接和网格条目会保留，并显示为不可用。")),
                primaryButton: .destructive(Text(FeatureL10n.string("删除"))) {
                    if automation.deleteWorkflow(id: workflow.id) {
                        selectedWorkflowID = automation.workflows.first?.id
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            selectInitialWorkflowIfNeeded()
            handleNavigationRevealRequest(navigationCoordinator.searchRevealRequest)
        }
        .onChange(of: automation.workflows.map(\.id)) { _, _ in
            selectInitialWorkflowIfNeeded()
        }
        .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
            handleNavigationRevealRequest(request)
        }
        .accessibilityIdentifier("mactools.automation")
    }

    private func splitDivider(
        sidebarWidth: CGFloat,
        maximumSidebarWidth: CGFloat
    ) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(SettingsStyle.separator)
                .frame(width: 1)
        }
        .frame(width: AutomationSplitViewLayout.dividerWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($workflowListDragTranslation) { value, translation, _ in
                    translation = value.translation.width
                }
                .onEnded { value in
                    workflowListWidth = AutomationSplitViewLayout.clampedSidebarWidth(
                        workflowListWidth + directionalTranslation(value.translation.width),
                        maximum: maximumSidebarWidth
                    )
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.resizeLeftRight.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            NSCursor.arrow.set()
        }
        .accessibilityElement()
        .accessibilityLabel(Text(FeatureL10n.string("工作流")))
        .accessibilityValue(Text("\(Int(sidebarWidth)) pt"))
        .accessibilityAdjustableAction { direction in
            let adjustment: CGFloat
            switch direction {
            case .increment:
                adjustment = AutomationSplitViewLayout.accessibilityAdjustment
            case .decrement:
                adjustment = -AutomationSplitViewLayout.accessibilityAdjustment
            @unknown default:
                return
            }
            workflowListWidth = AutomationSplitViewLayout.clampedSidebarWidth(
                workflowListWidth + adjustment,
                maximum: maximumSidebarWidth
            )
        }
    }

    private func directionalTranslation(_ translation: CGFloat) -> CGFloat {
        layoutDirection == .leftToRight ? translation : -translation
    }

    @ViewBuilder
    private var workflowDetail: some View {
        if let workflow = selectedWorkflow {
            WorkflowDetailView(
                pluginHost: pluginHost,
                automation: automation,
                workflow: workflow,
                previewBeforeRunning: $previewBeforeRunning,
                onRun: { requestRun($0) }
            )
            .id(workflow.id)
        } else {
            ContentUnavailableView(
                FeatureL10n.string("尚无工作流"),
                systemImage: "bolt.horizontal.circle",
                description: Text(FeatureL10n.string("创建工作流后，可组合多个 MacTools 操作。"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workflowList: some View {
        VStack(spacing: 0) {
            HStack {
                Label(FeatureL10n.string("自动化"), systemImage: "bolt.horizontal.circle")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                Button {
                    if let workflow = automation.createWorkflow() {
                        selectedWorkflowID = workflow.id
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(FeatureL10n.string("新建工作流"))
                .disabled(!automation.canEditDefinitions)
            }
            .padding(12)

            Divider()

            if automation.workflows.isEmpty {
                ContentUnavailableView(FeatureL10n.string("尚无工作流"), systemImage: "bolt.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedWorkflowID) {
                    ForEach(Array(automation.workflows.enumerated()), id: \.element.id) {
                        index, workflow in
                        WorkflowCollectionRow(
                            automation: automation,
                            workflow: workflow,
                            ruleCount: automation.rules(workflowID: workflow.id).count,
                            lastRun: automation.recentRuns(workflowID: workflow.id, limit: 1).first,
                            canMoveUp: index > 0,
                            canMoveDown: index + 1 < automation.workflows.count,
                            onRun: { requestRun(workflow) },
                            onDelete: { pendingDeleteWorkflow = workflow },
                            onMoveToTop: { moveWorkflow(workflow.id, to: 0) },
                            onMoveToBottom: {
                                moveWorkflow(workflow.id, to: automation.workflows.count - 1)
                            }
                        )
                        .moveDisabled(!automation.canEditDefinitions)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .tag(workflow.id)
                    }
                    .onMove(perform: moveWorkflows)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .background(SettingsStyle.contentBackground)
    }

    private var selectedWorkflow: WorkflowDefinition? {
        guard let selectedWorkflowID else {
            return nil
        }
        return automation.workflows.first { $0.id == selectedWorkflowID }
    }

    private func selectInitialWorkflowIfNeeded() {
        if let selectedWorkflowID,
           automation.workflows.contains(where: { $0.id == selectedWorkflowID }) {
            return
        }
        selectedWorkflowID = automation.workflows.first?.id
    }

    private func handleNavigationRevealRequest(_ request: SettingsSearchRevealRequest?) {
        guard
            let request,
            case let .automation(target) = request.target,
            automation.workflows.contains(where: { $0.id == target.workflowID })
        else {
            return
        }

        selectedWorkflowID = target.workflowID
        navigationCoordinator.clearSearchRevealRequest(request)
    }

    private func requestRun(_ workflow: WorkflowDefinition) {
        if previewBeforeRunning {
            previewRequest = WorkflowPreviewRequest(workflowID: workflow.id)
        } else {
            _ = automation.startWorkflow(id: workflow.id)
        }
    }

    private func moveWorkflows(fromOffsets sourceOffsets: IndexSet, toOffset destinationOffset: Int) {
        guard automation.canEditDefinitions,
              let move = WorkflowListReorder.move(
                  sourceOffsets: sourceOffsets,
                  destinationOffset: destinationOffset,
                  itemCount: automation.workflows.count
              ),
              automation.workflows.indices.contains(move.sourceIndex) else {
            return
        }
        let workflowID = automation.workflows[move.sourceIndex].id
        withAnimation(.easeInOut(duration: 0.18)) {
            automation.moveWorkflow(id: workflowID, offset: move.offset)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func moveWorkflow(_ workflowID: UUID, to destinationIndex: Int) {
        guard automation.canEditDefinitions,
              let sourceIndex = automation.workflows.firstIndex(where: { $0.id == workflowID }),
              automation.workflows.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            automation.moveWorkflow(id: workflowID, offset: destinationIndex - sourceIndex)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

private struct WorkflowPreviewRequest: Identifiable {
    let workflowID: UUID
    var id: UUID { workflowID }
}

private struct WorkflowCollectionRow: View {
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    let ruleCount: Int
    let lastRun: WorkflowRun?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRun: () -> Void
    let onDelete: () -> Void
    let onMoveToTop: () -> Void
    let onMoveToBottom: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: PluginSystemImage.resolvedName(workflow.systemImage))
                        .foregroundStyle(workflow.isEnabled ? Color.accentColor : .secondary)
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(summary)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(FeatureL10n.joined([workflow.name, summary]))

            Button {
                if isRunning {
                    automation.activeRunIDs(for: workflow.id).forEach(automation.cancel(runID:))
                } else {
                    onRun()
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 24)
            .disabled(!isRunning && (!workflow.isEnabled || workflow.steps.isEmpty))
            .help(isRunning ? FeatureL10n.string("停止当前工作流运行") : FeatureL10n.string("运行工作流"))
            .accessibilityLabel(
                isRunning
                    ? FeatureL10n.string("停止当前工作流运行")
                    : FeatureL10n.format("运行“%@”", workflow.name)
            )

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(automation.canEditDefinitions ? .secondary : .tertiary)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
                .help(FeatureL10n.format("调整“%@”的顺序", workflow.name))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button(moveToTopTitle, action: onMoveToTop)
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!canMoveUp)
            Button(moveToBottomTitle, action: onMoveToBottom)
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!canMoveDown)
            Divider()
            Button(FeatureL10n.string("创建副本")) { _ = automation.duplicateWorkflow(id: workflow.id) }
            Button(FeatureL10n.string("删除"), role: .destructive, action: onDelete)
        }
        .modifier(WorkflowKeyboardBoundaryMoveModifier(
            canMoveToTop: canMoveUp,
            canMoveToBottom: canMoveDown,
            moveToTop: onMoveToTop,
            moveToBottom: onMoveToBottom
        ))
        .modifier(WorkflowConditionalAccessibilityActionModifier(
            isEnabled: canMoveUp,
            name: moveToTopTitle,
            action: onMoveToTop
        ))
        .modifier(WorkflowConditionalAccessibilityActionModifier(
            isEnabled: canMoveDown,
            name: moveToBottomTitle,
            action: onMoveToBottom
        ))
    }

    private var summary: String {
        if isRunning {
            return FeatureL10n.format(
                "%d 个步骤 · %d 条规则 · %@",
                workflow.steps.count,
                ruleCount,
                FeatureL10n.string("运行中")
            )
        }
        let state = workflow.isEnabled ? FeatureL10n.string("已启用") : FeatureL10n.string("已停用")
        let last = lastRun.map {
            FeatureL10n.format(" · 上次%@", runStatusTitle($0.status))
        } ?? ""
        return FeatureL10n.format(
            "%d 个步骤 · %d 条规则 · %@%@",
            workflow.steps.count,
            ruleCount,
            state,
            last
        )
    }

    private var isRunning: Bool {
        !automation.activeRunIDs(for: workflow.id).isEmpty
    }

    private var moveToTopTitle: String {
        AppL10n.plugins("plugin.management.moveToTop", defaultValue: "移到顶部")
    }

    private var moveToBottomTitle: String {
        AppL10n.plugins("plugin.management.moveToBottom", defaultValue: "移到底部")
    }
}

private struct WorkflowDetailView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    @Binding var previewBeforeRunning: Bool
    let onRun: (WorkflowDefinition) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                header
                stepsSection
                runFromSection
                automaticRulesSection
                historySection

                if let error = automation.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                }
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
        }
        .disabled(!automation.canEditDefinitions)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                workflowIdentity
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                headerControls
                    .layoutPriority(2)
            }

            Text(FeatureL10n.string("按顺序运行多个操作；每个步骤都会重新检查可用性、权限和确认要求。"))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.standard)
    }

    private var workflowIdentity: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: PluginSystemImage.resolvedName(workflow.systemImage))
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)

            DebouncedAutomationTextField(
                FeatureL10n.string("工作流名称"),
                value: workflow.name,
                onCommit: { automation.renameWorkflow(id: workflow.id, name: $0) }
            )
            .font(PluginSettingsTheme.Typography.pageTitle)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerControls: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Toggle(
                FeatureL10n.string("启用"),
                isOn: Binding(
                    get: { workflow.isEnabled },
                    set: { automation.setWorkflowEnabled($0, id: workflow.id) }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()

            if activeWorkflowRunIDs.isEmpty {
                Button(FeatureL10n.string("运行")) {
                    onRun(workflow)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!workflow.isEnabled || workflow.steps.isEmpty)
                .fixedSize()
            } else {
                Button(FeatureL10n.string("停止"), role: .destructive) {
                    activeWorkflowRunIDs.forEach(automation.cancel(runID:))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .help(FeatureL10n.string("停止当前工作流运行"))
                .accessibilityIdentifier("mactools.automation.stop")
            }

        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var activeWorkflowRunIDs: [UUID] {
        automation.activeRunIDs(for: workflow.id)
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(FeatureL10n.string("步骤"), systemImage: "list.number")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                actionPicker
            }

            Text(FeatureL10n.string("步骤会在运行前等待。等待时间从上一步完成后开始；第一步从工作流开始时计算。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            if workflow.steps.isEmpty {
                ContentUnavailableView(
                    FeatureL10n.string("尚未添加步骤"),
                    systemImage: "plus.circle",
                    description: Text(FeatureL10n.string("从操作目录添加第一个步骤。"))
                )
                .frame(maxWidth: .infinity, minHeight: 150)
                .pluginSettingsCardBackground(.standard)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                        WorkflowStepEditor(
                            pluginHost: pluginHost,
                            automation: automation,
                            workflow: workflow,
                            step: step,
                            index: index,
                            canMoveUp: index > 0,
                            canMoveDown: index + 1 < workflow.steps.count
                        )
                        if index + 1 < workflow.steps.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }
        }
    }

    private var actionPicker: some View {
        WorkflowActionPicker(
            pluginHost: pluginHost,
            excluding: workflow.actionKey,
            select: {
                automation.addStep(workflowID: workflow.id, reference: $0)
            }
        )
        .disabled(workflow.steps.count >= WorkflowDefinition.maximumStepCount)
    }

    private var runFromSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(FeatureL10n.string("运行方式"), systemImage: "play.circle")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Label(FeatureL10n.string("统一搜索中可用"), systemImage: "magnifyingglass")
                if let item = pluginHost.actionShortcutSettingsItem(
                    for: workflow.actionReference
                ) {
                    Label(
                        FeatureL10n.format("全局快捷键：%@", item.bindingText),
                        systemImage: "command"
                    )
                } else {
                    Label(FeatureL10n.string("尚未分配全局快捷键"), systemImage: "command")
                        .foregroundStyle(.secondary)
                }
                ActionRunLinkControl(
                    pluginHost: pluginHost,
                    reference: workflow.actionReference
                )
                Toggle(FeatureL10n.string("运行前预览"), isOn: $previewBeforeRunning)
                    .toggleStyle(.switch)
                    .help(FeatureL10n.string("运行前检查步骤、可用性和确认要求。"))
                ForEach(
                    pluginHost.actionSurfaceAssignmentSummaries(
                        for: workflow.actionReference
                    ),
                    id: \.surfaceID
                ) { summary in
                    HStack {
                        Label(
                            "\(summary.surfaceTitle)：\(summary.detail)",
                            systemImage: summary.systemImage
                        )
                        Spacer()
                        Button(FeatureL10n.string("配置")) {
                            pluginHost.presentPluginSettings(pluginID: summary.surfaceID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Text(FeatureL10n.string("手势与操作网格由各自的功能页面管理。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var automaticRulesSection: some View {
        let automaticRuleAvailability = automation.automaticRuleAvailability(
            workflowID: workflow.id
        )
        let supportsAutomaticRules = automaticRuleAvailability.isAvailable
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(FeatureL10n.string("自动规则"), systemImage: "clock.arrow.circlepath")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    _ = automation.createRule(workflowID: workflow.id)
                } label: {
                    Label(FeatureL10n.string("添加规则"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!supportsAutomaticRules)
            }

            if !supportsAutomaticRules {
                Label(
                    automaticRuleAvailability.reason
                        ?? FeatureL10n.string("工作流包含不可用操作。"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.orange)
            }

            let rules = automation.rules(workflowID: workflow.id)
            if rules.isEmpty {
                Text(FeatureL10n.string("当前没有自动规则。手动运行不受规则条件影响。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding(PluginSettingsTheme.Spacing.cardContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsCardBackground(.standard)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        AutomationRuleEditor(
                            automation: automation,
                            rule: rule,
                            workflowName: workflow.name,
                            supportsBackground: supportsAutomaticRules
                        )
                        if index + 1 < rules.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }
        }
    }

    private var historySection: some View {
        let runs = automation.recentRuns(workflowID: workflow.id)
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(FeatureL10n.string("最近运行"), systemImage: "clock")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            if runs.isEmpty {
                Text(FeatureL10n.string("尚无运行记录。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding(PluginSettingsTheme.Spacing.cardContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsCardBackground(.standard)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        WorkflowRunRow(pluginHost: pluginHost, run: run)
                        if index + 1 < runs.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }
        }
    }
}

private enum WorkflowActionPickerFilter: String, CaseIterable, Identifiable {
    case available
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .available: FeatureL10n.string("可用")
        case .all: FeatureL10n.string("全部")
        }
    }
}

private struct WorkflowActionPickerItem: Identifiable {
    let entry: ActionCatalogEntry
    let ownerTitle: String
    let systemImage: String
    let availability: ActionAvailability
    let requiresConfirmation: Bool

    var id: ActionReference { entry.reference }
}

private struct WorkflowActionPickerGroup: Identifiable {
    let providerID: String
    let title: String
    let items: [WorkflowActionPickerItem]

    var id: String { providerID }
}

struct WorkflowActionPickerAccessibility: Equatable {
    let value: String

    init(availability: ActionAvailability, requiresConfirmation: Bool = false) {
        let availabilityValue = availability.isAvailable
            ? FeatureL10n.string("可用")
            : (availability.reason ?? FeatureL10n.string("不可用"))
        value = requiresConfirmation
            ? FeatureL10n.joined([
                availabilityValue,
                FeatureL10n.string("执行前需要确认。"),
            ])
            : availabilityValue
    }
}

private struct WorkflowActionPicker: View {
    @ObservedObject var pluginHost: PluginHost
    let excluding: ActionKey
    let select: (ActionReference) -> Void
    var buttonTitle = FeatureL10n.string("添加操作")
    var buttonSystemImage = "plus"
    var accessibilityIdentifier = "mactools.automation.add-action"

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(buttonTitle, systemImage: buttonSystemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            WorkflowActionPickerPopoverContent(
                pluginHost: pluginHost,
                excluding: excluding,
                select: { reference in
                    select(reference)
                    isPresented = false
                }
            )
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct WorkflowActionPickerPopoverContent: View {
    @ObservedObject var pluginHost: PluginHost
    let excluding: ActionKey
    let select: (ActionReference) -> Void
    @State private var query = ""
    @State private var filter: WorkflowActionPickerFilter = .available

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(FeatureL10n.string("搜索操作、插件或快捷键"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mactools.automation.action-picker.search")

            Picker(FeatureL10n.string("筛选"), selection: $filter) {
                ForEach(WorkflowActionPickerFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            if groups.isEmpty {
                ContentUnavailableView(
                    FeatureL10n.string("没有匹配的操作"),
                    systemImage: "magnifyingglass",
                    description: Text(FeatureL10n.string("调整搜索词或筛选条件后重试。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title)
                                    .font(PluginSettingsTheme.Typography.sectionTitle)
                                    .foregroundStyle(.secondary)

                                ForEach(group.items) { item in
                                    let accessibility = WorkflowActionPickerAccessibility(
                                        availability: item.availability,
                                        requiresConfirmation: item.requiresConfirmation
                                    )
                                    Button {
                                        select(item.entry.reference)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: PluginSystemImage.resolvedName(item.systemImage))
                                                .frame(width: 22)
                                                .foregroundStyle(item.availability.isAvailable ? Color.accentColor : .secondary)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.entry.title)
                                                    .font(PluginSettingsTheme.Typography.rowTitle)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                if let subtitle = item.entry.subtitle {
                                                    Text(subtitle)
                                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                                if !item.availability.isAvailable {
                                                    Text(item.availability.reason ?? FeatureL10n.string("不可用"))
                                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                                        .foregroundStyle(.orange)
                                                        .lineLimit(2)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                            if item.requiresConfirmation {
                                                Image(systemName: "exclamationmark.shield")
                                                    .foregroundStyle(.orange)
                                                    .help(FeatureL10n.string("执行前需要确认。"))
                                                    .accessibilityHidden(true)
                                            }

                                            if !item.availability.isAvailable {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundStyle(.orange)
                                                    .help(item.availability.reason ?? FeatureL10n.string("不可用"))
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!item.availability.isAvailable)
                                    .accessibilityValue(Text(accessibility.value))
                                    .accessibilityIdentifier(
                                        "mactools.automation.action-picker.\(item.entry.reference.key.id)"
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(width: 470, height: 500)
    }

    private var groups: [WorkflowActionPickerGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = pluginHost.actionCatalogEntries.compactMap { entry -> WorkflowActionPickerItem? in
            guard entry.reference.key != excluding,
                  case let .success(action) = pluginHost.actionRegistry.registeredAction(
                      for: entry.reference
                  ) else {
                return nil
            }
            let availability = pluginHost.actionAvailability(for: entry.reference)
            guard filter == .all || availability.isAvailable else {
                return nil
            }
            let ownerTitle = pluginHost.actionSurfaceOwnerTitle(
                providerID: entry.reference.key.providerID
            )
            guard normalizedQuery.isEmpty || [
                entry.title,
                entry.subtitle,
                ownerTitle,
                action.definition.description,
            ].compactMap({ $0 }).contains(where: {
                $0.localizedCaseInsensitiveContains(normalizedQuery)
            }) else {
                return nil
            }
            return WorkflowActionPickerItem(
                entry: entry,
                ownerTitle: ownerTitle,
                systemImage: action.definition.systemImage,
                availability: availability,
                requiresConfirmation: action.definition.risk == .confirmationRequired
            )
        }

        var providerOrder: [String] = []
        var grouped: [String: [WorkflowActionPickerItem]] = [:]
        for item in items {
            let providerID = item.entry.reference.key.providerID
            if grouped[providerID] == nil {
                providerOrder.append(providerID)
            }
            grouped[providerID, default: []].append(item)
        }
        return providerOrder.compactMap { providerID in
            guard let items = grouped[providerID], let first = items.first else { return nil }
            return WorkflowActionPickerGroup(
                providerID: providerID,
                title: first.ownerTitle,
                items: items
            )
        }
    }
}

private struct AutomationRuleEditor: View {
    @ObservedObject var automation: AutomationController
    let rule: AutomationRule
    let workflowName: String
    let supportsBackground: Bool
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                DebouncedAutomationTextField(
                    FeatureL10n.string("规则名称"),
                    value: rule.name,
                    onCommit: { value in
                        var updated = rule
                        updated.name = value
                        automation.saveRule(updated)
                    }
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)

                HStack {
                    Text(FeatureL10n.string("当"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Picker(FeatureL10n.string("触发器"), selection: triggerKindBinding) {
                        ForEach(AutomationTriggerKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 150, maxWidth: 220)
                    Spacer()
                    triggerAvailabilityView
                }

                triggerConfiguration

                HStack {
                    Text(FeatureL10n.string("如果"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(
                        rule.conditions.isEmpty
                            ? FeatureL10n.string("无附加条件")
                            : FeatureL10n.format(
                                "满足全部 %d 个条件",
                                rule.conditions.count
                            )
                    )
                        .foregroundStyle(.secondary)
                    Spacer()
                    conditionMenu
                }

                ForEach(rule.conditions) { condition in
                    AutomationConditionEditor(
                        condition: condition,
                        onChange: { replaceCondition($0) },
                        onDelete: { removeCondition(condition) }
                    )
                    .padding(.leading, 24)
                }

                HStack {
                    Text(FeatureL10n.string("运行"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(workflowName)
                    Spacer()
                    Button(FeatureL10n.string("创建副本")) { _ = automation.duplicateRule(id: rule.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(FeatureL10n.string("删除"), role: .destructive) { automation.deleteRule(id: rule.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: triggerIcon)
                    .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(
                        AutomationRuleSummaryFormatter.summary(
                            trigger: rule.trigger,
                            conditionCount: rule.conditions.count,
                            workflowName: workflowName
                        )
                    )
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(FeatureL10n.string("启用"), isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .accessibilityIdentifier("mactools.automation.rule.\(rule.id.uuidString)")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { enabled in
                guard !enabled || supportsBackground else { return }
                var updated = rule
                updated.isEnabled = enabled
                automation.saveRule(updated)
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AutomationRule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { value in
                var updated = rule
                updated[keyPath: keyPath] = value
                automation.saveRule(updated)
            }
        )
    }

    private var triggerKindBinding: Binding<AutomationTriggerKind> {
        Binding(
            get: { rule.trigger.kind },
            set: { kind in
                var updated = rule
                updated.trigger = .defaultValue(for: kind)
                automation.saveRule(updated)
            }
        )
    }

    @ViewBuilder
    private var triggerConfiguration: some View {
        switch rule.trigger {
        case let .schedule(value):
            HStack {
                Stepper("\(twoDigits(value.hour)):\(twoDigits(value.minute))", value: triggerIntBinding(value.hour, range: 0 ... 23) { .schedule(replacing(value, hour: $0)) }, in: 0 ... 23)
                Stepper(FeatureL10n.format("分钟 %d", value.minute), value: triggerIntBinding(value.minute, range: 0 ... 59) { .schedule(replacing(value, minute: $0)) }, in: 0 ... 59)
            }
            weekdayEditor(value.weekdays) { .schedule(replacing(value, weekdays: $0)) }
        case let .calendar(value):
            HStack {
                Picker(FeatureL10n.string("时机"), selection: triggerValueBinding(value.phase) { .calendar(replacing(value, phase: $0)) }) {
                    Text(FeatureL10n.string("开始")).tag(CalendarAutomationPhase.starts)
                    Text(FeatureL10n.string("结束")).tag(CalendarAutomationPhase.ends)
                }
                .frame(maxWidth: 150)
                Stepper(FeatureL10n.format("偏移 %d 分钟", value.offsetMinutes), value: triggerIntBinding(value.offsetMinutes, range: -1_440 ... 1_440) { .calendar(replacing(value, offsetMinutes: $0)) }, in: -1_440 ... 1_440)
            }
            DebouncedAutomationTextField(
                FeatureL10n.string("标题包含（可选）"),
                value: value.titleContains ?? "",
                onCommit: { saveTrigger(.calendar(replacing(value, titleContains: $0.isEmpty ? nil : $0))) }
            )
                .textFieldStyle(.roundedBorder)
            if !automation.triggerAvailability(for: .calendar).isAvailable {
                Button(FeatureL10n.string("允许访问日历")) {
                    Task { await automation.requestCalendarAccess() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case let .application(value):
            HStack {
                Picker(FeatureL10n.string("事件"), selection: triggerValueBinding(value.event) { .application(replacing(value, event: $0)) }) {
                    Text(FeatureL10n.string("启动")).tag(ApplicationAutomationEvent.launches)
                    Text(FeatureL10n.string("激活")).tag(ApplicationAutomationEvent.activates)
                }
                .frame(maxWidth: 150)
                DebouncedAutomationTextField(
                    FeatureL10n.string("应用 Bundle ID"),
                    value: value.bundleIdentifier,
                    onCommit: { saveTrigger(.application(replacing(value, bundleIdentifier: $0))) }
                )
                    .textFieldStyle(.roundedBorder)
            }
        case let .power(value):
            HStack {
                Picker(FeatureL10n.string("事件"), selection: triggerValueBinding(value.event) { .power(replacing(value, event: $0)) }) {
                    Text(FeatureL10n.string("接入电源")).tag(PowerAutomationEvent.adapterConnected)
                    Text(FeatureL10n.string("断开电源")).tag(PowerAutomationEvent.adapterDisconnected)
                    Text(FeatureL10n.string("电量降至阈值")).tag(PowerAutomationEvent.batteryAtOrBelow)
                }
                .frame(maxWidth: 180)
                if value.event == .batteryAtOrBelow {
                    Stepper("\(value.batteryLevel)%", value: triggerIntBinding(value.batteryLevel, range: 0 ... 100) { .power(replacing(value, batteryLevel: $0)) }, in: 0 ... 100)
                }
            }
        case let .display(value):
            HStack {
                Picker(FeatureL10n.string("事件"), selection: triggerValueBinding(value.event) { .display(replacing(value, event: $0)) }) {
                    Text(FeatureL10n.string("连接")).tag(DisplayAutomationEvent.connected)
                    Text(FeatureL10n.string("断开")).tag(DisplayAutomationEvent.disconnected)
                }
                .frame(maxWidth: 150)
                DebouncedAutomationTextField(
                    FeatureL10n.string("显示器名称包含（可选）"),
                    value: value.displayNameContains ?? "",
                    onCommit: { saveTrigger(.display(replacing(value, displayNameContains: $0.isEmpty ? nil : $0))) }
                )
                    .textFieldStyle(.roundedBorder)
            }
        case let .network(value):
            HStack {
                Picker(FeatureL10n.string("状态"), selection: triggerValueBinding(value.status) { .network(replacing(value, status: $0)) }) {
                    Text(FeatureL10n.string("可用")).tag(AutomationNetworkStatus.available)
                    Text(FeatureL10n.string("不可用")).tag(AutomationNetworkStatus.unavailable)
                }
                Picker(FeatureL10n.string("接口"), selection: triggerValueBinding(value.interface) { .network(replacing(value, interface: $0)) }) {
                    ForEach(AutomationNetworkInterface.allCases, id: \.self) { interface in
                        Text(networkInterfaceTitle(interface)).tag(interface)
                    }
                }
            }
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private var triggerAvailabilityView: some View {
        let availability = automation.triggerAvailability(for: rule.trigger.kind)
        if availability.isAvailable {
            Label(FeatureL10n.string("可用"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(PluginSettingsTheme.Typography.statusBadge)
        } else {
            Label(availability.reason ?? FeatureL10n.string("不可用"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(PluginSettingsTheme.Typography.rowDescription)
        }
    }

    private var conditionMenu: some View {
        Menu {
            conditionButton(FeatureL10n.string("当前应用"), condition: .frontmostApplication(FrontmostApplicationCondition(bundleIdentifier: "com.apple.finder")))
            conditionButton(FeatureL10n.string("电池与电源"), condition: .power(PowerAutomationCondition()))
            conditionButton(FeatureL10n.string("已连接显示器"), condition: .connectedDisplay(ConnectedDisplayCondition()))
            conditionButton(FeatureL10n.string("时间范围"), condition: .timeRange(TimeRangeAutomationCondition()))
            conditionButton(FeatureL10n.string("网络状态"), condition: .network(NetworkAutomationCondition()))
        } label: {
            Label(FeatureL10n.string("添加条件"), systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(rule.conditions.count >= AutomationRule.maximumConditionCount)
    }

    private func conditionButton(_ title: String, condition: AutomationCondition) -> some View {
        Button(title) {
            guard !rule.conditions.contains(where: { $0.id == condition.id }) else { return }
            var updated = rule
            updated.conditions.append(condition)
            automation.saveRule(updated)
        }
        .disabled(rule.conditions.contains(where: { $0.id == condition.id }))
    }

    private func replaceCondition(_ condition: AutomationCondition) {
        guard let index = rule.conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        var updated = rule
        updated.conditions[index] = condition
        automation.saveRule(updated)
    }

    private func removeCondition(_ condition: AutomationCondition) {
        var updated = rule
        updated.conditions.removeAll { $0.id == condition.id }
        automation.saveRule(updated)
    }

    private func saveTrigger(_ trigger: AutomationTrigger) {
        var updated = rule
        updated.trigger = trigger
        automation.saveRule(updated)
    }

    private func triggerValueBinding<Value>(_ value: Value, make: @escaping (Value) -> AutomationTrigger) -> Binding<Value> {
        Binding(get: { value }, set: { saveTrigger(make($0)) })
    }

    private func triggerIntBinding(_ value: Int, range: ClosedRange<Int>, make: @escaping (Int) -> AutomationTrigger) -> Binding<Int> {
        Binding(get: { value }, set: { saveTrigger(make(min(max($0, range.lowerBound), range.upperBound))) })
    }

    private func triggerStringBinding(_ value: String, make: @escaping (String) -> AutomationTrigger) -> Binding<String> {
        Binding(get: { value }, set: { saveTrigger(make($0)) })
    }

    private func optionalTriggerStringBinding(_ value: String?, make: @escaping (String?) -> AutomationTrigger) -> Binding<String> {
        Binding(get: { value ?? "" }, set: { saveTrigger(make($0.isEmpty ? nil : $0)) })
    }

    private func weekdayEditor(_ weekdays: [Int], make: @escaping ([Int]) -> AutomationTrigger) -> some View {
        HStack(spacing: 4) {
            ForEach(1 ... 7, id: \.self) { weekday in
                Button(weekdayTitle(weekday)) {
                    var updated = Set(weekdays)
                    if updated.contains(weekday), updated.count > 1 {
                        updated.remove(weekday)
                    } else {
                        updated.insert(weekday)
                    }
                    saveTrigger(make(updated.sorted()))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(weekdays.contains(weekday) ? .accentColor : .secondary)
            }
        }
    }

    private var triggerIcon: String {
        switch rule.trigger.kind {
        case .schedule: "clock"
        case .calendar: "calendar"
        case .application: "app"
        case .power: "bolt"
        case .display: "display"
        case .network: "network"
        }
    }

}

@MainActor
enum AutomationRuleSummaryFormatter {
    static func summary(
        trigger: AutomationTrigger,
        conditionCount: Int,
        workflowName: String
    ) -> String {
        let trigger = triggerSummary(for: trigger)
        if conditionCount == 0 {
            return FeatureL10n.format("当 %@ · 运行 %@", trigger, workflowName)
        }
        return FeatureL10n.format(
            "当 %@，且满足 %d 个条件 · 运行 %@",
            trigger,
            conditionCount,
            workflowName
        )
    }

    static func triggerSummary(for trigger: AutomationTrigger) -> String {
        switch trigger {
        case let .schedule(value):
            FeatureL10n.format(
                "每周指定日期 %@:%@",
                twoDigits(value.hour),
                twoDigits(value.minute)
            )
        case let .calendar(value):
            value.phase == .starts
                ? FeatureL10n.string("日历事件开始")
                : FeatureL10n.string("日历事件结束")
        case let .application(value):
            value.event == .launches
                ? FeatureL10n.format("应用 %@ 启动", value.bundleIdentifier)
                : FeatureL10n.format("应用 %@ 激活", value.bundleIdentifier)
        case let .power(value): powerEventTitle(value.event)
        case let .display(value):
            value.event == .connected
                ? FeatureL10n.string("显示器连接")
                : FeatureL10n.string("显示器断开")
        case let .network(value):
            value.status == .available
                ? FeatureL10n.string("网络变为可用")
                : FeatureL10n.string("网络变为不可用")
        }
    }
}

private struct AutomationConditionEditor: View {
    let condition: AutomationCondition
    let onChange: (AutomationCondition) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            conditionFields
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var conditionFields: some View {
        switch condition {
        case let .frontmostApplication(value):
            Text(FeatureL10n.string("当前应用"))
            Picker(FeatureL10n.string("匹配"), selection: binding(value.isExcluded) { .frontmostApplication(replacing(value, isExcluded: $0)) }) {
                Text(FeatureL10n.string("是")).tag(false)
                Text(FeatureL10n.string("不是")).tag(true)
            }
            .labelsHidden()
            .frame(width: 70)
            TextField(
                FeatureL10n.string("应用 Bundle ID"),
                text: binding(value.bundleIdentifier) {
                    .frontmostApplication(replacing(value, bundleIdentifier: $0))
                }
            )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 280)
        case let .power(value):
            Text(FeatureL10n.string("电源"))
            Picker(FeatureL10n.string("来源"), selection: powerSourceBinding(value)) {
                Text(FeatureL10n.string("任意")).tag("any")
                Text(FeatureL10n.string("电源适配器")).tag(AutomationPowerSource.adapter.rawValue)
                Text(FeatureL10n.string("电池")).tag(AutomationPowerSource.battery.rawValue)
            }
            .labelsHidden()
            .frame(width: 130)
            Stepper(FeatureL10n.format("最低 %d%%", value.minimumBatteryLevel ?? 0), value: optionalLevelBinding(value, minimum: true), in: 0 ... 100)
            Stepper(FeatureL10n.format("最高 %d%%", value.maximumBatteryLevel ?? 100), value: optionalLevelBinding(value, minimum: false), in: 0 ... 100)
        case let .connectedDisplay(value):
            Text(FeatureL10n.string("显示器已连接"))
            TextField(FeatureL10n.string("名称包含"), text: optionalStringBinding(value.displayNameContains) { .connectedDisplay(replacing(value, displayNameContains: $0)) })
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 240)
        case let .timeRange(value):
            Text(FeatureL10n.string("时间"))
            Stepper(FeatureL10n.format("从 %@", minuteTitle(value.startMinute)), value: binding(value.startMinute) { .timeRange(replacing(value, startMinute: $0)) }, in: 0 ... 1_439, step: 15)
            Stepper(FeatureL10n.format("至 %@", minuteTitle(value.endMinute)), value: binding(value.endMinute) { .timeRange(replacing(value, endMinute: $0)) }, in: 0 ... 1_439, step: 15)
        case let .network(value):
            Text(FeatureL10n.string("网络"))
            Picker(FeatureL10n.string("状态"), selection: binding(value.status) { .network(replacing(value, status: $0)) }) {
                Text(FeatureL10n.string("可用")).tag(AutomationNetworkStatus.available)
                Text(FeatureL10n.string("不可用")).tag(AutomationNetworkStatus.unavailable)
            }
            .labelsHidden()
            Picker(FeatureL10n.string("接口"), selection: binding(value.interface) { .network(replacing(value, interface: $0)) }) {
                ForEach(AutomationNetworkInterface.allCases, id: \.self) { interface in
                    Text(networkInterfaceTitle(interface)).tag(interface)
                }
            }
            .labelsHidden()
        }
    }

    private func binding<Value>(_ value: Value, make: @escaping (Value) -> AutomationCondition) -> Binding<Value> {
        Binding(get: { value }, set: { onChange(make($0)) })
    }

    private func optionalStringBinding(_ value: String?, make: @escaping (String?) -> AutomationCondition) -> Binding<String> {
        Binding(get: { value ?? "" }, set: { onChange(make($0.isEmpty ? nil : $0)) })
    }

    private func powerSourceBinding(_ value: PowerAutomationCondition) -> Binding<String> {
        Binding(
            get: { value.source?.rawValue ?? "any" },
            set: { rawValue in
                onChange(.power(replacing(value, source: AutomationPowerSource(rawValue: rawValue))))
            }
        )
    }

    private func optionalLevelBinding(_ value: PowerAutomationCondition, minimum: Bool) -> Binding<Int> {
        Binding(
            get: { minimum ? (value.minimumBatteryLevel ?? 0) : (value.maximumBatteryLevel ?? 100) },
            set: { level in
                if minimum {
                    onChange(.power(replacing(value, minimumBatteryLevel: min(level, value.maximumBatteryLevel ?? 100))))
                } else {
                    onChange(.power(replacing(value, maximumBatteryLevel: max(level, value.minimumBatteryLevel ?? 0))))
                }
            }
        )
    }
}

private func replacing(_ value: ScheduleAutomationTrigger, hour: Int? = nil, minute: Int? = nil, weekdays: [Int]? = nil) -> ScheduleAutomationTrigger {
    ScheduleAutomationTrigger(hour: hour ?? value.hour, minute: minute ?? value.minute, weekdays: weekdays ?? value.weekdays)
}

private func replacing(_ value: CalendarAutomationTrigger, phase: CalendarAutomationPhase? = nil, titleContains: String?? = nil, offsetMinutes: Int? = nil) -> CalendarAutomationTrigger {
    CalendarAutomationTrigger(phase: phase ?? value.phase, calendarIdentifier: value.calendarIdentifier, titleContains: titleContains ?? value.titleContains, offsetMinutes: offsetMinutes ?? value.offsetMinutes)
}

private func replacing(_ value: ApplicationAutomationTrigger, event: ApplicationAutomationEvent? = nil, bundleIdentifier: String? = nil) -> ApplicationAutomationTrigger {
    ApplicationAutomationTrigger(event: event ?? value.event, bundleIdentifier: bundleIdentifier ?? value.bundleIdentifier)
}

private func replacing(_ value: PowerAutomationTrigger, event: PowerAutomationEvent? = nil, batteryLevel: Int? = nil) -> PowerAutomationTrigger {
    PowerAutomationTrigger(event: event ?? value.event, batteryLevel: batteryLevel ?? value.batteryLevel)
}

private func replacing(_ value: DisplayAutomationTrigger, event: DisplayAutomationEvent? = nil, displayNameContains: String?? = nil) -> DisplayAutomationTrigger {
    DisplayAutomationTrigger(event: event ?? value.event, displayIdentifier: value.displayIdentifier, displayNameContains: displayNameContains ?? value.displayNameContains)
}

private func replacing(_ value: NetworkAutomationTrigger, status: AutomationNetworkStatus? = nil, interface: AutomationNetworkInterface? = nil) -> NetworkAutomationTrigger {
    NetworkAutomationTrigger(status: status ?? value.status, interface: interface ?? value.interface)
}

private func replacing(_ value: FrontmostApplicationCondition, isExcluded: Bool? = nil, bundleIdentifier: String? = nil) -> FrontmostApplicationCondition {
    FrontmostApplicationCondition(bundleIdentifier: bundleIdentifier ?? value.bundleIdentifier, isExcluded: isExcluded ?? value.isExcluded)
}

private func replacing(_ value: PowerAutomationCondition, source: AutomationPowerSource?? = nil, minimumBatteryLevel: Int?? = nil, maximumBatteryLevel: Int?? = nil) -> PowerAutomationCondition {
    PowerAutomationCondition(source: source ?? value.source, minimumBatteryLevel: minimumBatteryLevel ?? value.minimumBatteryLevel, maximumBatteryLevel: maximumBatteryLevel ?? value.maximumBatteryLevel)
}

private func replacing(_ value: ConnectedDisplayCondition, displayNameContains: String?? = nil) -> ConnectedDisplayCondition {
    ConnectedDisplayCondition(displayIdentifier: value.displayIdentifier, displayNameContains: displayNameContains ?? value.displayNameContains)
}

private func replacing(_ value: TimeRangeAutomationCondition, startMinute: Int? = nil, endMinute: Int? = nil) -> TimeRangeAutomationCondition {
    TimeRangeAutomationCondition(startMinute: startMinute ?? value.startMinute, endMinute: endMinute ?? value.endMinute, weekdays: value.weekdays)
}

private func replacing(_ value: NetworkAutomationCondition, status: AutomationNetworkStatus? = nil, interface: AutomationNetworkInterface? = nil) -> NetworkAutomationCondition {
    NetworkAutomationCondition(status: status ?? value.status, interface: interface ?? value.interface)
}

private func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }
private func minuteTitle(_ value: Int) -> String { "\(twoDigits(value / 60)):\(twoDigits(value % 60))" }
private func weekdayTitle(_ value: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = PluginRuntimeLocalization.locale
    let symbols = formatter.veryShortWeekdaySymbols ?? []
    let index = max(1, min(7, value)) - 1
    return symbols.indices.contains(index) ? symbols[index] : String(value)
}

private func networkInterfaceTitle(_ value: AutomationNetworkInterface) -> String {
    switch value {
    case .any: FeatureL10n.string("任意")
    case .wifi: "Wi-Fi"
    case .wiredEthernet: FeatureL10n.string("以太网")
    case .cellular: FeatureL10n.string("蜂窝网络")
    case .other: FeatureL10n.string("其他")
    }
}

private func powerEventTitle(_ value: PowerAutomationEvent) -> String {
    switch value {
    case .adapterConnected: FeatureL10n.string("接入电源")
    case .adapterDisconnected: FeatureL10n.string("断开电源")
    case .batteryAtOrBelow: FeatureL10n.string("电量降至阈值")
    }
}

private struct DebouncedAutomationTextField: View {
    let title: String
    let value: String
    let onCommit: (String) -> Void
    @State private var draft: String

    init(
        _ title: String,
        value: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft)
            .task(id: draft) {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                commit()
            }
            .onChange(of: value) { _, newValue in
                if draft != newValue {
                    draft = newValue
                }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

private struct DebouncedAutomationDoubleField: View {
    let title: String
    let value: Double
    let onCommit: (Double) -> Void
    @State private var draft: Double

    init(
        _ title: String,
        value: Double,
        onCommit: @escaping (Double) -> Void
    ) {
        self.title = title
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(
            title,
            value: $draft,
            format: .number.precision(.fractionLength(0 ... 1))
        )
        .task(id: draft) {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            commit()
        }
        .onChange(of: value) { _, newValue in
            if draft != newValue {
                draft = newValue
            }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let clamped = min(max(0, draft), WorkflowStep.maximumDelaySeconds)
        guard clamped != value else { return }
        onCommit(clamped)
    }
}

private struct WorkflowStepEditor: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    let step: WorkflowStep
    let index: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    @State private var isAdvancedExpanded = false
    @State private var isReplacementPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text("\(index + 1)")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(actionTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(actionDescription)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !availability.isAvailable {
                        Text(availability.reason ?? FeatureL10n.string("操作不可用。"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ControlGroup {
                    Button {
                        isReplacementPickerPresented = true
                    } label: {
                        Label(
                            FeatureL10n.string("替换操作"),
                            systemImage: "rectangle.2.swap"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(FeatureL10n.string("替换操作"))
                    .accessibilityIdentifier(
                        "mactools.automation.replace-action.\(step.id.uuidString)"
                    )

                    Button { automation.moveStep(workflowID: workflow.id, stepID: step.id, offset: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .accessibilityLabel(FeatureL10n.string("上移"))
                    .help(FeatureL10n.string("上移"))
                    .disabled(!canMoveUp)
                    Button { automation.moveStep(workflowID: workflow.id, stepID: step.id, offset: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel(FeatureL10n.string("下移"))
                    .help(FeatureL10n.string("下移"))
                    .disabled(!canMoveDown)
                    Button(role: .destructive) {
                        automation.removeStep(workflowID: workflow.id, stepID: step.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(FeatureL10n.string("删除"))
                    .help(FeatureL10n.string("删除"))
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .popover(isPresented: $isReplacementPickerPresented, arrowEdge: .bottom) {
                    WorkflowActionPickerPopoverContent(
                        pluginHost: pluginHost,
                        excluding: workflow.actionKey,
                        select: { reference in
                            automation.replaceStepReference(
                                workflowID: workflow.id,
                                stepID: step.id,
                                reference: reference
                            )
                            isReplacementPickerPresented = false
                        }
                    )
                }
            }

            DisclosureGroup(
                FeatureL10n.string("高级选项"),
                isExpanded: $isAdvancedExpanded
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        stepOptions
                    }
                    VStack(alignment: .leading, spacing: 8) { stepOptions }
                }
                .padding(.top, 8)
            }
            .padding(.leading, 30)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .accessibilityIdentifier("mactools.workflow.step.\(step.id.uuidString)")
    }

    @ViewBuilder
    private var stepOptions: some View {
        DebouncedAutomationTextField(
            FeatureL10n.string("步骤名称（可选）"),
            value: step.label ?? "",
            onCommit: { update(label: $0) }
        )
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)

        HStack(spacing: 6) {
            Text(FeatureL10n.string("步骤前等待"))
            DebouncedAutomationDoubleField(
                FeatureL10n.string("秒"),
                value: step.delaySeconds,
                onCommit: { update(delay: $0) }
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .accessibilityLabel(Text(FeatureL10n.string("步骤前等待")))
            .accessibilityIdentifier("mactools.workflow.step.\(step.id.uuidString).delay")
            Text(FeatureL10n.string("秒"))
        }

        Picker(
            FeatureL10n.string("失败时"),
            selection: Binding(
                get: { step.errorPolicy },
                set: { update(policy: $0) }
            )
        ) {
            Text(FeatureL10n.string("停止")).tag(WorkflowStepErrorPolicy.stop)
            Text(FeatureL10n.string("继续")).tag(WorkflowStepErrorPolicy.continueRunning)
        }
        .frame(minWidth: 130, maxWidth: 170)
    }

    private var actionTitle: String {
        automation.catalogEntry(for: step.reference)?.title
            ?? automation.definition(for: step.reference)?.title
            ?? step.reference.key.id
    }

    private var actionDescription: String {
        automation.definition(for: step.reference)?.description
            ?? FeatureL10n.string("操作说明不可用。")
    }

    private var availability: ActionAvailability {
        automation.availability(for: step.reference)
    }

    private func update(
        label: String? = nil,
        delay: Double? = nil,
        policy: WorkflowStepErrorPolicy? = nil
    ) {
        automation.updateStep(
            workflowID: workflow.id,
            stepID: step.id,
            label: label ?? step.label,
            delaySeconds: delay ?? step.delaySeconds,
            errorPolicy: policy ?? step.errorPolicy
        )
    }
}

private struct WorkflowRunPreviewSheet: View {
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    let onRun: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: 6) {
                Label(FeatureL10n.string("运行前预览"), systemImage: "checklist")
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Text(FeatureL10n.string("工作流会按顺序更改系统状态；已完成的步骤无法自动撤销。"))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                        previewRow(index: index, step: step)
                        if index + 1 < workflow.steps.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }

            HStack {
                if !canRun {
                    Label(
                        FeatureL10n.string("请先修复不可用的步骤。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
                }
                Spacer()
                Button(FeatureL10n.string("取消"), role: .cancel) { dismiss() }
                Button(FeatureL10n.string("运行")) {
                    dismiss()
                    onRun()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            }
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var canRun: Bool {
        workflow.isEnabled
            && !workflow.steps.isEmpty
            && workflow.steps.allSatisfy { automation.availability(for: $0.reference).isAvailable }
    }

    private func previewRow(index: Int, step: WorkflowStep) -> some View {
        let definition = automation.definition(for: step.reference)
        let availability = automation.availability(for: step.reference)
        return HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text("\(index + 1)")
                .font(PluginSettingsTheme.Typography.statusBadge)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(step.label ?? definition?.title ?? step.reference.key.id)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                if let description = definition?.description {
                    Text(description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                if step.delaySeconds > 0 {
                    Label(
                        FeatureL10n.format("运行前等待 %@ 秒", step.delaySeconds.formatted(.number.locale(PluginRuntimeLocalization.locale))),
                        systemImage: "clock"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                }
                if definition?.risk == .confirmationRequired {
                    Label(FeatureL10n.string("此步骤会在执行前要求确认。"), systemImage: "exclamationmark.shield")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                }
                if !availability.isAvailable {
                    Label(
                        availability.reason ?? FeatureL10n.string("操作不可用。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pluginSettingsListRowPadding(interactive: false)
    }
}

private struct WorkflowRunRow: View {
    @ObservedObject var pluginHost: PluginHost
    let run: WorkflowRun

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(WorkflowRunPresentation.sourceTitle(run.source), systemImage: "arrow.triangle.branch")
                    Spacer()
                    Text(WorkflowRunPresentation.durationTitle(run))
                    Button {
                        ActionRunLinkClipboard.copy(
                            WorkflowRunPresentation.diagnosticText(
                                run,
                                registry: pluginHost.actionRegistry
                            )
                        )
                    } label: {
                        Label(FeatureL10n.string("复制"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("mactools.automation.run.\(run.id.uuidString).copy")
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

                ForEach(run.stepResults) { result in
                    HStack {
                        Image(systemName: stepStatusImage(result.status))
                            .foregroundStyle(stepStatusColor(result.status))
                        Text(
                            WorkflowHistoryPresentation.actionTitle(
                                for: result,
                                registry: pluginHost.actionRegistry
                            )
                        )
                        Spacer()
                        Text(stepStatusTitle(result.status))
                            .foregroundStyle(.secondary)
                    }
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    if let message = result.localizedMessage {
                        Text(message)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label(runStatusTitle(run.status), systemImage: runStatusImage(run.status))
                    .foregroundStyle(runStatusColor(run.status))
                Text(run.startedAt, style: .relative)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(FeatureL10n.format("%d 个步骤", run.stepResults.count))
                    .foregroundStyle(.secondary)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

}

@MainActor
enum WorkflowRunPresentation {
    static func sourceTitle(_ source: WorkflowRunSource) -> String {
        switch source {
        case .manual:
            FeatureL10n.string("手动")
        case .test:
            FeatureL10n.string("测试")
        case let .publishedAction(actionSource):
            switch actionSource {
            case .globalShortcut: FeatureL10n.string("全局快捷键")
            case .runLink: FeatureL10n.string("运行链接")
            case .actionGrid: FeatureL10n.string("操作网格")
            case .trackpadGesture: FeatureL10n.string("触控板手势")
            case .unifiedSearch: FeatureL10n.string("统一搜索")
            case .workflow: FeatureL10n.string("工作流")
            case .automaticRule: FeatureL10n.string("自动规则")
            case .appIntent: FeatureL10n.string("App Intent")
            case .cli: FeatureL10n.string("命令行")
            case .manual: FeatureL10n.string("手动")
            case .test: FeatureL10n.string("测试")
            }
        case .automatic:
            FeatureL10n.string("自动规则")
        }
    }

    static func durationTitle(_ run: WorkflowRun) -> String {
        guard let finishedAt = run.finishedAt else {
            return FeatureL10n.string("运行中")
        }
        let seconds = max(0, finishedAt.timeIntervalSince(run.startedAt))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                .locale(PluginRuntimeLocalization.locale)
        )
    }

    static func diagnosticText(
        _ run: WorkflowRun,
        registry: ActionRegistry
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Workflow: \(run.workflowName)",
            "Run ID: \(run.id.uuidString.lowercased())",
            "Status: \(run.status.rawValue)",
            "Source: \(sourceTitle(run.source))",
            "Started: \(formatter.string(from: run.startedAt))",
            "Finished: \(run.finishedAt.map(formatter.string(from:)) ?? "-")",
            "Duration: \(durationTitle(run))",
        ]
        if let summary = run.localizedSummary, !summary.isEmpty {
            lines.append("Summary: \(summary)")
        }
        for (index, result) in run.stepResults.enumerated() {
            let title = WorkflowHistoryPresentation.actionTitle(for: result, registry: registry)
            var line = "Step \(index + 1): \(title) [\(result.status.rawValue)]"
            if let message = result.localizedMessage, !message.isEmpty {
                line += " — \(message)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum WorkflowHistoryPresentation {
    static func actionTitle(
        for result: WorkflowStepRunResult,
        registry: ActionRegistry
    ) -> String {
        guard result.titleSource != .custom else {
            return result.title
        }
        let reference = result.actionReference ?? ActionReference(key: result.actionKey)
        if case let .success(action) = registry.registeredAction(for: reference) {
            return action.catalogEntry?.title ?? action.definition.title
        }
        return registry.definition(for: result.actionKey)?.title ?? result.title
    }
}

private func runStatusTitle(_ status: WorkflowRunStatus) -> String {
    switch status {
    case .running: FeatureL10n.string("运行中")
    case .succeeded: FeatureL10n.string("成功")
    case .failed: FeatureL10n.string("失败")
    case .cancelled: FeatureL10n.string("已取消")
    case .interrupted: FeatureL10n.string("已中断")
    case .skipped: FeatureL10n.string("已跳过")
    }
}

private func runStatusImage(_ status: WorkflowRunStatus) -> String {
    switch status {
    case .running: "progress.indicator"
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "stop.circle.fill"
    case .interrupted: "exclamationmark.circle.fill"
    case .skipped: "forward.end.circle"
    }
}

private func runStatusColor(_ status: WorkflowRunStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .running: .blue
    case .failed, .interrupted: .red
    case .cancelled, .skipped: .secondary
    }
}

private func stepStatusTitle(_ status: WorkflowStepRunStatus) -> String {
    switch status {
    case .succeeded: FeatureL10n.string("成功")
    case .failed: FeatureL10n.string("失败")
    case .cancelled: FeatureL10n.string("已取消")
    case .timedOut: FeatureL10n.string("超时")
    case .unavailable: FeatureL10n.string("不可用")
    case .skipped: FeatureL10n.string("已跳过")
    }
}

private func stepStatusImage(_ status: WorkflowStepRunStatus) -> String {
    switch status {
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "stop.circle.fill"
    case .timedOut: "clock.badge.exclamationmark"
    case .unavailable: "questionmark.circle.fill"
    case .skipped: "forward.end.circle"
    }
}

private func stepStatusColor(_ status: WorkflowStepRunStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .failed, .timedOut, .unavailable: .red
    case .cancelled, .skipped: .secondary
    }
}
