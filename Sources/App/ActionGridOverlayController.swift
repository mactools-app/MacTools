import AppKit
import MacToolsPluginKit
import OSLog
import SwiftUI

enum ActionSurfaceExecutionSupport {
    static func preferredMode(for definition: ActionDefinition) -> ActionExecutionMode? {
        if definition.capabilities.contains(.foregroundInteractive) {
            return .foreground
        }
        if definition.capabilities.contains(.background) {
            return .background
        }
        return nil
    }

    static func continuesAfterSurfaceDismissal(for definition: ActionDefinition) -> Bool {
        definition.capabilities.contains(.reportsProgress)
    }

    static func feedback(for outcome: ActionExecutionOutcome) -> String? {
        switch outcome {
        case .completed(.succeeded): nil
        case let .completed(.failed(message)): message
        case .completed(.cancelled): FeatureL10n.string("操作已取消。")
        case let .rejected(rejection): message(for: rejection)
        }
    }

    static func message(for rejection: ActionExecutionRejection) -> String {
        switch rejection {
        case .unknownAction: FeatureL10n.string("找不到对应操作。")
        case let .invalidParameters(reason): FeatureL10n.format("操作参数无效：%@", reason)
        case let .unavailable(reason): reason ?? FeatureL10n.string("操作不可用。")
        case .backgroundExecutionUnsupported: FeatureL10n.string("操作不能在后台运行。")
        case .foregroundExecutionUnsupported: FeatureL10n.string("操作不能以交互方式运行。")
        case .automaticExecutionUnsupported: FeatureL10n.string("此操作未获准自动运行。")
        case .confirmationRequiredForAutomaticExecution:
            FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
        case .externalInvocationUnavailable: FeatureL10n.string("此操作不允许从外部调用。")
        case .systemExposureUnavailable: FeatureL10n.string("操作不可用。")
        case .confirmationUnavailable: FeatureL10n.string("无法显示操作确认。")
        case .confirmationDenied: FeatureL10n.string("操作已取消。")
        case .confirmationTimedOut: FeatureL10n.string("确认已超时。")
        case .actionAlreadyRunning: FeatureL10n.string("此操作正在运行。")
        case .providerChanged: FeatureL10n.string("操作提供方已发生变化，请重试。")
        case let .providerFailure(message): message
        case .executionTimedOut: FeatureL10n.string("操作超时。")
        }
    }
}

enum ActionGridExecutionOutcome: Equatable {
    case terminal(ActionExecutionOutcome)
    case handedOff
}

struct ResolvedActionGridEntry: Identifiable, Equatable {
    let id: String
    let reference: ActionReference
    let title: String
    let invocationTitle: String?
    let subtitle: String?
    let compactDetail: String?
    let ownerTitle: String
    let systemImage: String
    let availability: ActionAvailability
    let presentationState: ActionPresentationState?
    var slotIndex: Int = 0
    var children: [ActionGridPresentationEntry]? = nil

    var isFolder: Bool { children != nil }

    var stateLabel: String? {
        switch presentationState {
        case .active:
            FeatureL10n.string("已开启")
        case .inactive:
            FeatureL10n.string("已关闭")
        case nil:
            nil
        }
    }

    var tileStatus: String? {
        guard availability.isAvailable else {
            return FeatureL10n.string("不可用")
        }
        if let children {
            switch children.count {
            case 0:
                return FeatureL10n.string("空文件夹")
            case 1:
                return FeatureL10n.string("1 个操作")
            default:
                return FeatureL10n.format("%d 个操作", children.count)
            }
        }
        if let stateLabel {
            return Self.compactJoined([stateLabel, compactDetail])
        }
        return distinct(compactDetail, from: [title])
    }

    var helpText: String {
        Self.uniqueLines([
            title,
            tileStatus,
            distinct(invocationTitle, from: [title]),
            distinct(subtitle, from: [title, tileStatus, invocationTitle]),
            availability.isAvailable ? nil : availability.reason,
            distinct(ownerTitle, from: [title, tileStatus, invocationTitle, subtitle]),
        ])
        .joined(separator: "\n")
    }

    var accessibilityValue: String {
        Self.uniqueLines([
            tileStatus,
            availability.isAvailable
                ? FeatureL10n.string("可用")
                : (availability.reason ?? FeatureL10n.string("不可用")),
        ])
        .joined(separator: ", ")
    }

    init(
        id: String,
        reference: ActionReference,
        title: String,
        invocationTitle: String? = nil,
        subtitle: String? = nil,
        compactDetail: String? = nil,
        ownerTitle: String,
        systemImage: String,
        availability: ActionAvailability,
        presentationState: ActionPresentationState? = nil,
        slotIndex: Int = 0,
        children: [ActionGridPresentationEntry]? = nil
    ) {
        self.id = id
        self.reference = reference
        self.title = title
        self.invocationTitle = invocationTitle
        self.subtitle = subtitle
        self.compactDetail = compactDetail
        self.ownerTitle = ownerTitle
        self.systemImage = systemImage
        self.availability = availability
        self.presentationState = presentationState
        self.slotIndex = slotIndex
        self.children = children
    }

    var accessibilityLabel: String {
        FeatureL10n.joined(Self.uniqueLines([
            title,
            distinct(ownerTitle, from: [title]),
        ]))
    }

    var accessibilityHint: String {
        guard availability.isAvailable else {
            return availability.reason ?? FeatureL10n.string("操作不可用。")
        }
        return distinct(invocationTitle, from: [title]) ?? ""
    }

    private func distinct(_ value: String?, from comparisons: [String?]) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let normalizedComparisons = comparisons.compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalizedComparisons.contains(where: {
            value.localizedCaseInsensitiveCompare($0) == .orderedSame
        }) else {
            return nil
        }
        return value
    }

    private static func compactJoined(_ values: [String?]) -> String? {
        let values = uniqueLines(values)
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func uniqueLines(_ values: [String?]) -> [String] {
        var seen: [String] = []
        for value in values {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !seen.contains(where: {
                      value.localizedCaseInsensitiveCompare($0) == .orderedSame
                  }) else {
                continue
            }
            seen.append(value)
        }
        return seen
    }
}

enum ActionGridKeyboardDirection: Equatable {
    case left
    case right
    case up
    case down
}

enum ActionGridKeyCommand: Equatable {
    case dismiss
    case move(ActionGridKeyboardDirection)
    case activateSelected
    case select(Int)

    private static let disallowedModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
    ]

    static func resolve(
        keyCode: UInt16,
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags = [],
        layoutDirection: LayoutDirection = .leftToRight
    ) -> ActionGridKeyCommand? {
        guard modifierFlags.intersection(disallowedModifiers).isEmpty else {
            return nil
        }
        return switch keyCode {
        case 53: .dismiss
        case 123: .move(layoutDirection == .rightToLeft ? .right : .left)
        case 124: .move(layoutDirection == .rightToLeft ? .left : .right)
        case 125: .move(.down)
        case 126: .move(.up)
        case 36, 76: .activateSelected
        default:
            if let characters, let number = Int(characters), (1 ... 9).contains(number) {
                .select(number)
            } else {
                nil
            }
        }
    }
}

enum ActionGridKeyboardNavigation {
    static func preferredInitialSlot(
        occupiedSlots: Set<Int>,
        columns: Int = 3,
        maximumSlots: Int = ActionGridPresentationLimits.maximumEntriesPerGrid
    ) -> Int {
        guard !occupiedSlots.isEmpty, columns > 0, maximumSlots > 0 else { return 0 }
        let validSlots = occupiedSlots.filter { (0 ..< maximumSlots).contains($0) }
        guard !validSlots.isEmpty else { return 0 }
        let centerSlot = min(maximumSlots - 1, (maximumSlots / 2))
        let centerRow = centerSlot / columns
        let centerColumn = centerSlot % columns

        return validSlots
            .min { lhs, rhs in
                let lhsDistance = abs(lhs / columns - centerRow) + abs(lhs % columns - centerColumn)
                let rhsDistance = abs(rhs / columns - centerRow) + abs(rhs % columns - centerColumn)
                return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
            } ?? 0
    }

    static func nextIndex(
        from current: Int,
        direction: ActionGridKeyboardDirection,
        itemCount: Int,
        columns: Int
    ) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        let index = min(max(0, current), itemCount - 1)
        let candidate: Int = switch direction {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columns
        case .down: index + columns
        }
        guard (0 ..< itemCount).contains(candidate) else { return index }
        if direction == .left, index % columns == 0 { return index }
        if direction == .right, index % columns == columns - 1 { return index }
        return candidate
    }

    static func nextOccupiedSlot(
        from current: Int,
        direction: ActionGridKeyboardDirection,
        occupiedSlots: Set<Int>,
        columns: Int = 3,
        maximumSlots: Int = ActionGridPresentationLimits.maximumEntriesPerGrid
    ) -> Int {
        guard occupiedSlots.contains(current), columns > 0 else {
            return occupiedSlots.min() ?? 0
        }
        let step: Int = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }
        var candidate = current + step
        while (0 ..< maximumSlots).contains(candidate) {
            if direction == .left, candidate / columns != current / columns { break }
            if direction == .right, candidate / columns != current / columns { break }
            if occupiedSlots.contains(candidate) { return candidate }
            candidate += step
        }
        return current
    }
}

enum ActionGridOverlayGeometry {
    static let tileWidth: CGFloat = 160
    static let tileHeight: CGFloat = 116
    static let gridSpacing: CGFloat = 12
    static let contentPadding: CGFloat = 16
    static let nestedMinimumContentWidth: CGFloat = 256
    static let emptyStateHeight: CGFloat = 104
    private static let navigationHeaderHeight: CGFloat = 28
    private static let navigationHeaderSpacing: CGFloat = 12
    private static let feedbackHeight: CGFloat = 36
    private static let feedbackSpacing: CGFloat = 12

    static func columnCount(for itemCount: Int, isNested: Bool = false) -> Int {
        guard itemCount > 0 else { return 0 }
        return isNested ? min(3, itemCount) : 3
    }

    static func contentSize(
        for itemCount: Int,
        includesNavigationHeader: Bool = false,
        includesFeedback: Bool = false
    ) -> CGSize {
        let isNested = includesNavigationHeader
        let columns = max(1, columnCount(for: itemCount, isNested: isNested))
        let rows = max(1, Int(ceil(Double(max(1, itemCount)) / Double(columns))))
        let gridWidth = CGFloat(columns) * tileWidth
            + CGFloat(columns - 1) * gridSpacing
        let contentWidth = isNested ? max(gridWidth, nestedMinimumContentWidth) : gridWidth
        let contentHeight = itemCount == 0 ? emptyStateHeight : CGFloat(rows) * tileHeight
            + CGFloat(rows - 1) * gridSpacing
        return CGSize(
            width: contentWidth + contentPadding * 2,
            height: contentHeight + contentPadding * 2
                + (includesNavigationHeader
                    ? navigationHeaderHeight + navigationHeaderSpacing
                    : 0)
                + (includesFeedback ? feedbackHeight + feedbackSpacing : 0)
        )
    }

    static func targetFrame(
        pointer: CGPoint,
        visibleFrame: CGRect,
        itemCount: Int,
        includesNavigationHeader: Bool = false,
        includesFeedback: Bool = false
    ) -> CGRect {
        let size = contentSize(
            for: itemCount,
            includesNavigationHeader: includesNavigationHeader,
            includesFeedback: includesFeedback
        )
        let margin: CGFloat = 10
        let preferredOrigin = CGPoint(
            x: pointer.x - size.width / 2,
            y: pointer.y - size.height / 2
        )
        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - size.width - margin
        let minimumY = visibleFrame.minY + margin
        let maximumY = visibleFrame.maxY - size.height - margin
        let origin = CGPoint(
            x: maximumX >= minimumX
                ? min(max(preferredOrigin.x, minimumX), maximumX)
                : visibleFrame.midX - size.width / 2,
            y: maximumY >= minimumY
                ? min(max(preferredOrigin.y, minimumY), maximumY)
                : visibleFrame.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }
}

enum ActionGridScreenSelection {
    static func screenIndex(
        containing pointer: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        if let containingIndex = screenFrames.firstIndex(where: { $0.contains(pointer) }) {
            return containingIndex
        }
        return screenFrames.indices.min { lhs, rhs in
            squaredDistance(from: pointer, to: screenFrames[lhs])
                < squaredDistance(from: pointer, to: screenFrames[rhs])
        }
    }

    private static func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let deltaX = max(max(frame.minX - point.x, 0), point.x - frame.maxX)
        let deltaY = max(max(frame.minY - point.y, 0), point.y - frame.maxY)
        return deltaX * deltaX + deltaY * deltaY
    }
}

enum ActionGridPointerActivationPolicy {
    /// Prevents the touch release that completed a trackpad gesture from
    /// becoming a click on the cell that appears beneath the pointer.
    static let presentationGraceInterval: TimeInterval = 0.35
    static let trackpadPresentationGraceInterval: TimeInterval = 0.8

    static func acceptsPointerEvent(
        eventUptime: TimeInterval,
        presentationUptime: TimeInterval,
        source: ActionExecutionSource
    ) -> Bool {
        let interval = source == .trackpadGesture
            ? trackpadPresentationGraceInterval
            : presentationGraceInterval
        return eventUptime - presentationUptime >= interval
    }
}

struct ActionGridOverlayAccessibilityPolicy: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    var animatesSelection: Bool { !reduceMotion }
    var usesMaterialBackground: Bool { !reduceTransparency }
}

@MainActor
final class ActionGridOverlayModel: ObservableObject {
    private struct NavigationLevel {
        let title: String
        let entries: [ActionGridPresentationEntry]
        let selectedIndex: Int
    }

    @Published private(set) var entries: [ResolvedActionGridEntry] = []
    @Published var selectedIndex = 0
    @Published private(set) var feedback: String?
    @Published private(set) var isExecuting = false
    @Published private(set) var executingEntryID: String?
    @Published private(set) var folderPath: [String] = []

    private let resolver: (ActionGridPresentationEntry) -> ResolvedActionGridEntry
    private let executor: (ActionReference) async -> ActionGridExecutionOutcome
    private var sourceEntries: [ActionGridPresentationEntry] = []
    private var navigationStack: [NavigationLevel] = []
    private var executionTask: Task<Void, Never>?
    private var executionGeneration: UInt = 0
    var onSuccessfulExecution: (() -> Void)?
    var onLayoutChange: ((Int, Bool, Bool) -> Void)?

    init(
        resolver: @escaping (ActionGridPresentationEntry) -> ResolvedActionGridEntry,
        executor: @escaping (ActionReference) async -> ActionGridExecutionOutcome
    ) {
        self.resolver = resolver
        self.executor = executor
    }

    var columns: Int {
        ActionGridOverlayGeometry.columnCount(for: slotCount, isNested: !isAtRoot)
    }
    @Published private(set) var slotCount = 0
    var isAtRoot: Bool { navigationStack.isEmpty }
    var navigationTitle: String? { folderPath.last }

    func update(_ entries: [ActionGridPresentationEntry]) {
        invalidateExecution()
        navigationStack = []
        folderPath = []
        sourceEntries = entries
        refreshLocalization()
        selectedIndex = preferredInitialSelection()
        setFeedback(nil)
    }

    func refreshLocalization() {
        entries = sourceEntries.enumerated().map { offset, entry in
            var resolved = resolver(entry)
            resolved.slotIndex = entry.slotIndex ?? offset
            return resolved
        }
        .sorted { $0.slotIndex < $1.slotIndex }
        slotCount = entries.isEmpty
            ? 0
            : min(
                ActionGridPresentationLimits.maximumEntriesPerGrid,
                (entries.map(\.slotIndex).max() ?? 0) + 1
            )
        notifyLayoutChange()
        if entry(at: selectedIndex) == nil {
            selectedIndex = preferredInitialSelection()
        }
    }

    func move(_ direction: ActionGridKeyboardDirection) {
        selectedIndex = ActionGridKeyboardNavigation.nextOccupiedSlot(
            from: selectedIndex,
            direction: direction,
            occupiedSlots: Set(entries.map(\.slotIndex)),
            columns: columns
        )
    }

    func select(number: Int) {
        let index = number - 1
        guard entry(at: index) != nil else { return }
        selectedIndex = index
        activateSelected()
    }

    func activateSelected() {
        guard let entry = entry(at: selectedIndex) else { return }
        activate(entry)
    }

    func activate(_ entry: ResolvedActionGridEntry) {
        guard !isExecuting else { return }
        if let children = entry.children {
            navigationStack.append(
                NavigationLevel(
                    title: entry.title,
                    entries: sourceEntries,
                    selectedIndex: selectedIndex
                )
            )
            folderPath.append(entry.title)
            sourceEntries = children
            setFeedback(nil)
            refreshLocalization()
            selectedIndex = preferredInitialSelection()
            return
        }
        guard entry.availability.isAvailable else {
            setFeedback(entry.availability.reason ?? FeatureL10n.string("操作不可用。"))
            return
        }
        isExecuting = true
        executingEntryID = entry.id
        setFeedback(nil)
        let generation = executionGeneration
        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await executor(entry.reference)
            guard generation == executionGeneration else { return }
            executionTask = nil
            isExecuting = false
            executingEntryID = nil
            switch outcome {
            case .handedOff, .terminal(.completed(.succeeded)):
                onSuccessfulExecution?()
            case let .terminal(.completed(.failed(message))):
                setFeedback(message)
            case .terminal(.completed(.cancelled)):
                setFeedback(FeatureL10n.string("操作已取消。"))
            case let .terminal(.rejected(rejection)):
                setFeedback(ActionSurfaceExecutionSupport.message(for: rejection))
            }
        }
    }

    func invalidateExecution() {
        executionGeneration &+= 1
        executionTask?.cancel()
        executionTask = nil
        isExecuting = false
        executingEntryID = nil
    }

    private func preferredInitialSelection() -> Int {
        ActionGridKeyboardNavigation.preferredInitialSlot(
            occupiedSlots: Set(entries.map(\.slotIndex)),
            columns: columns
        )
    }

    @discardableResult
    func navigateBack() -> Bool {
        guard let level = navigationStack.popLast() else { return false }
        sourceEntries = level.entries
        selectedIndex = level.selectedIndex
        if !folderPath.isEmpty { folderPath.removeLast() }
        setFeedback(nil)
        refreshLocalization()
        return true
    }

    private func setFeedback(_ value: String?) {
        guard feedback != value else { return }
        feedback = value
        notifyLayoutChange()
    }

    private func notifyLayoutChange() {
        onLayoutChange?(slotCount, !isAtRoot, feedback != nil)
    }

    func entry(at slot: Int) -> ResolvedActionGridEntry? {
        entries.first { $0.slotIndex == slot }
    }
}

private final class ActionGridOverlayPanel: NSPanel {
    var keyEventHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyEventHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class ActionGridDismissTokens {
    var localMouse: Any?

    func removeAll() {
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        localMouse = nil
    }

    deinit { removeAll() }
}

@MainActor
enum ActionGridSuccessfulExecutionFocusPolicy {
    static func shouldRestorePreviousApplication(
        panelIsKey: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        panelIsKey && applicationIsActive
    }
}

struct ActionGridResizeContext: Equatable {
    let pointer: CGPoint
    let screenIndex: Int
}

enum ActionGridResizeScreenSelection {
    static func context(
        presentationPointer: CGPoint,
        panelFrame: CGRect,
        screenFrames: [CGRect]
    ) -> ActionGridResizeContext? {
        guard !screenFrames.isEmpty else { return nil }
        if let index = screenFrames.firstIndex(where: { $0.contains(presentationPointer) }) {
            return ActionGridResizeContext(pointer: presentationPointer, screenIndex: index)
        }

        let relocatedPanelCenter = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        guard let index = ActionGridScreenSelection.screenIndex(
            containing: relocatedPanelCenter,
            screenFrames: screenFrames
        ) else {
            return nil
        }
        return ActionGridResizeContext(pointer: relocatedPanelCenter, screenIndex: index)
    }
}

@MainActor
final class ActionGridOverlayController: NSObject, NSWindowDelegate {
    typealias ConfirmationPresenter = @MainActor (
        ActionConfirmationRequest,
        NSWindow
    ) async -> Bool

    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.action-grid.overlay")
    private let pluginHost: PluginHost
    private let model: ActionGridOverlayModel
    private let confirmationRouter: ActionConfirmationRouter
    private let tokens = ActionGridDismissTokens()
    private var panel: ActionGridOverlayPanel?
    private let focusRestoration = PluginPanelFocusRestoration()
    private let dismissalMonitor = PluginPanelDismissalMonitor()
    private var presentationUptime: TimeInterval = 0
    private var presentationSource = ActionExecutionSource.manual
    private var presentationPointer: CGPoint?
    private var presentationVisibleFrame: CGRect?
    private var presentationGeneration: UInt = 0
    private var isPresentingConfirmation = false
    private let confirmationPresenter: ConfirmationPresenter?

    init(
        pluginHost: PluginHost,
        confirmationPresenter: ConfirmationPresenter? = nil
    ) {
        self.pluginHost = pluginHost
        self.confirmationPresenter = confirmationPresenter
        let confirmationRouter = ActionConfirmationRouter()
        self.confirmationRouter = confirmationRouter
        self.model = ActionGridOverlayModel(
            resolver: { [weak pluginHost] entry in
                if let children = entry.children {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? FeatureL10n.string("文件夹"),
                        ownerTitle: FeatureL10n.string("文件夹"),
                        systemImage: entry.folderSystemImage ?? "folder.fill",
                        availability: .available,
                        children: children
                    )
                }
                guard let pluginHost,
                      case let .success(action) = pluginHost.actionRegistry.registeredAction(for: entry.reference) else {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? FeatureL10n.string("操作不可用。"),
                        ownerTitle: entry.reference.key.providerID,
                        systemImage: "questionmark.square.dashed",
                        availability: .unavailable(FeatureL10n.string("操作提供方当前不可用。"))
                    )
                }
                let ownerTitle = pluginHost.actionSurfaceOwnerTitle(
                    providerID: entry.reference.key.providerID
                )
                let invocationTitle = action.catalogEntry?.title ?? action.definition.title
                return ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: entry.customTitle ?? Self.compactTitle(
                        for: entry.reference,
                        action: action
                    ),
                    invocationTitle: invocationTitle,
                    subtitle: action.catalogEntry?.subtitle,
                    compactDetail: Self.compactDetail(
                        for: entry.reference,
                        action: action
                    ),
                    ownerTitle: ownerTitle,
                    systemImage: action.definition.systemImage,
                    availability: pluginHost.actionRegistry.availability(for: entry.reference),
                    presentationState: action.catalogEntry?.presentationState
                )
            },
            executor: { [weak pluginHost] reference in
                guard let pluginHost else {
                    return .terminal(.rejected(
                        .unavailable(FeatureL10n.string("操作提供方当前不可用。"))
                    ))
                }
                guard case let .success(action) = pluginHost.actionRegistry.registeredAction(
                    for: reference
                ), let mode = ActionSurfaceExecutionSupport.preferredMode(
                    for: action.definition
                ) else {
                    return .terminal(.rejected(.unknownAction(reference.key)))
                }
                let invocation = ActionInvocation(
                    reference: reference,
                    source: .actionGrid,
                    mode: mode
                )
                if ActionSurfaceExecutionSupport.continuesAfterSurfaceDismissal(
                    for: action.definition
                ) {
                    switch await pluginHost.actionExecutor.startContinuing(
                        invocation,
                        expectedDefinition: action.definition,
                        confirmationService: confirmationRouter
                    ) {
                    case .started:
                        return .handedOff
                    case .cancelled:
                        return .terminal(.completed(.cancelled))
                    case let .rejected(rejection):
                        return .terminal(.rejected(rejection))
                    }
                }
                return .terminal(await pluginHost.actionExecutor.execute(
                    invocation,
                    confirmationService: confirmationRouter
                ))
            }
        )
        super.init()
        confirmationRouter.setHandler { [weak self] request in
            await self?.confirmAction(request) ?? false
        }
        model.onSuccessfulExecution = { [weak self] in
            self?.closeAfterSuccessfulExecution()
        }
        model.onLayoutChange = { [weak self] slotCount, includesNavigationHeader, includesFeedback in
            self?.resizePanel(
                for: slotCount,
                includesNavigationHeader: includesNavigationHeader,
                includesFeedback: includesFeedback
            )
        }
    }

    private func confirmAction(_ request: ActionConfirmationRequest) async -> Bool {
        guard let panel, panel.isVisible else { return false }
        isPresentingConfirmation = true
        defer { isPresentingConfirmation = false }
        if let confirmationPresenter {
            return await confirmationPresenter(request, panel)
        }
        let service = AppActionConfirmationService { [weak panel] in panel }
        return await service.confirm(request)
    }

    private static func compactTitle(
        for reference: ActionReference,
        action: RegisteredAction
    ) -> String {
        if reference.key.providerID == "mactools",
           let hostAction = AppShortcutAction(rawValue: reference.key.actionID) {
            return hostAction.compactTitle
        }
        if action.catalogEntry?.presentationState != nil {
            return action.definition.title
        }
        return action.catalogEntry?.title ?? action.definition.title
    }

    private static func compactDetail(
        for reference: ActionReference,
        action: RegisteredAction
    ) -> String? {
        guard reference.key.providerID != "mactools" else { return nil }
        guard action.catalogEntry?.presentationState != nil else {
            return action.catalogEntry?.subtitle
        }
        guard action.catalogEntry?.presentationState == .active,
              ["auto-input", "keep-awake"].contains(reference.key.providerID) else {
            return nil
        }
        return action.catalogEntry?.subtitle
    }

    var isShown: Bool { panel != nil }
    var presentedEntryIDs: [String] { model.entries.map(\.id) }
    var presentedEntries: [ResolvedActionGridEntry] { model.entries }
    var presentedSelectedIndex: Int { model.selectedIndex }
    var presentedPanelFrame: CGRect? { panel?.frame }
    var presentedPanelCollectionBehavior: NSWindow.CollectionBehavior? {
        panel?.collectionBehavior
    }

    @discardableResult
    func present(
        entries: [ActionGridPresentationEntry],
        source: ActionExecutionSource = .manual
    ) -> Bool {
        guard (1 ... ActionGridPresentationLimits.maximumEntriesPerGrid).contains(entries.count),
              Self.hasValidSlots(entries) else {
            return false
        }
        pluginHost.refreshActionPresentations(
            providerIDs: statefulProviderIDs(in: entries)
        )
        presentationUptime = ProcessInfo.processInfo.systemUptime
        presentationSource = source
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let screenIndex = ActionGridScreenSelection.screenIndex(
            containing: pointer,
            screenFrames: screens.map(\.frame)
        ) else {
            return false
        }
        let screen = screens[screenIndex]
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationPointer = pointer
        presentationVisibleFrame = screen.visibleFrame
        model.update(entries)
        AppLog.actionGrid.debug(
            "Present requested at pointer (\(pointer.x, privacy: .public), \(pointer.y, privacy: .public)) on \(screen.localizedName, privacy: .public) with visible frame \(String(describing: screen.visibleFrame), privacy: .public)"
        )
        if let panel {
            let frame = ActionGridOverlayGeometry.targetFrame(
                pointer: pointer,
                visibleFrame: screen.visibleFrame,
                itemCount: model.slotCount,
                includesNavigationHeader: !model.isAtRoot,
                includesFeedback: model.feedback != nil
            )
            installDismissHandlers(panel: panel)
            orderPanel(panel, at: frame, intendedScreen: screen, generation: generation)
            return true
        }
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: pointer,
            visibleFrame: screen.visibleFrame,
            itemCount: model.slotCount
        )
        let panel = ActionGridOverlayPanel(
            contentRect: frame,
            styleMask: PluginPanelPresentation.styleMask,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.delegate = self
        panel.identifier = Self.panelIdentifier
        panel.setAccessibilityLabel(FeatureL10n.string("操作网格"))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        PluginPanelPresentation.configure(panel)
        panel.level = .popUpMenu
        panel.keyEventHandler = { [weak self] event in self?.processKeyEvent(event) ?? false }
        panel.contentView = NSHostingView(
            rootView: ActionGridOverlayRootView(
                model: model,
                onDismiss: { [weak self] in self?.close() }
            )
        )
        focusRestoration.prepareForPresentation()
        self.panel = panel
        installDismissHandlers(panel: panel)
        orderPanel(panel, at: frame, intendedScreen: screen, generation: generation)
        return true
    }

    private func orderPanel(
        _ panel: NSPanel,
        at frame: CGRect,
        intendedScreen: NSScreen,
        generation: UInt
    ) {
        // AppKit may apply its Space placement policy while ordering a panel. Set the
        // desired frame on both sides of that operation so the pointer's display wins.
        panel.setFrame(frame, display: true, animate: false)
        PluginPanelPresentation.present(panel)
        panel.setFrame(frame, display: true, animate: false)
        logPanelPlacement(panel, intendedScreen: intendedScreen)

        // Reassert once after AppKit finishes the current ordering transaction. A
        // generation guard prevents an older request from overriding a newer display.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel,
                  self.panel === panel,
                  self.presentationGeneration == generation else {
                return
            }
            panel.setFrame(frame, display: true, animate: false)
            self.logPanelPlacement(panel, intendedScreen: intendedScreen)
        }
    }

    private func logPanelPlacement(_ panel: NSPanel, intendedScreen: NSScreen) {
        let actualScreen = panel.screen?.localizedName ?? "None"
        AppLog.actionGrid.debug(
            "Action Grid frame \(String(describing: panel.frame), privacy: .public); intended screen \(intendedScreen.localizedName, privacy: .public); actual screen \(actualScreen, privacy: .public)"
        )
    }

    private static func hasValidSlots(_ entries: [ActionGridPresentationEntry]) -> Bool {
        let resolvedSlots = entries.enumerated().map { offset, entry in entry.slotIndex ?? offset }
        guard resolvedSlots.allSatisfy({
            (0 ..< ActionGridPresentationLimits.maximumEntriesPerGrid).contains($0)
        }), Set(resolvedSlots).count == resolvedSlots.count else {
            return false
        }
        return entries.allSatisfy { entry in
            entry.children.map(Self.hasValidSlots) ?? true
        }
    }

    private func statefulProviderIDs(
        in entries: [ActionGridPresentationEntry]
    ) -> Set<String> {
        Set(entries.flatMap(actionReferences(in:)).compactMap { reference in
            guard case let .success(action) = pluginHost.actionRegistry.registeredAction(
                for: reference
            ), action.catalogEntry?.presentationState != nil else {
                return nil
            }
            return reference.key.providerID
        })
    }

    private func actionReferences(
        in entry: ActionGridPresentationEntry
    ) -> [ActionReference] {
        if let children = entry.children {
            return children.flatMap(actionReferences(in:))
        }
        return [entry.reference]
    }

    func close(restoringFocus: Bool = true) {
        model.invalidateExecution()
        guard let panel else { return }
        presentationGeneration &+= 1
        tokens.removeAll()
        dismissalMonitor.stop()
        panel.keyEventHandler = nil
        panel.delegate = nil
        self.panel = nil
        panel.orderOut(nil)
        panel.close()
        focusRestoration.dismiss(wasVisible: true, restoringFocus: restoringFocus)
        presentationPointer = nil
        presentationVisibleFrame = nil
        isPresentingConfirmation = false
    }

    private func closeAfterSuccessfulExecution() {
        let shouldRestoreFocus = ActionGridSuccessfulExecutionFocusPolicy
            .shouldRestorePreviousApplication(
                panelIsKey: panel?.isKeyWindow == true,
                applicationIsActive: NSApp.isActive
            )
        close(restoringFocus: shouldRestoreFocus)
    }

    private func resizePanel(
        for slotCount: Int,
        includesNavigationHeader: Bool,
        includesFeedback: Bool
    ) {
        guard let panel, let presentationPointer else { return }
        let screens = NSScreen.screens
        guard let context = ActionGridResizeScreenSelection.context(
            presentationPointer: presentationPointer,
            panelFrame: panel.frame,
            screenFrames: screens.map(\.frame)
        ), screens.indices.contains(context.screenIndex) else {
            return
        }
        let presentationVisibleFrame = screens[context.screenIndex].visibleFrame
        self.presentationPointer = context.pointer
        self.presentationVisibleFrame = presentationVisibleFrame
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: context.pointer,
            visibleFrame: presentationVisibleFrame,
            itemCount: slotCount,
            includesNavigationHeader: includesNavigationHeader,
            includesFeedback: includesFeedback
        )
        panel.setFrame(frame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        if panel != nil { close() }
    }

    func processKeyEvent(_ event: NSEvent) -> Bool {
        guard let command = ActionGridKeyCommand.resolve(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            layoutDirection: ActionGridOverlayRootView.layoutDirection(
                for: PluginRuntimeLocalization.locale
            )
        ) else {
            return false
        }
        switch command {
        case .dismiss:
            if !model.navigateBack() {
                close()
            }
        case let .move(direction):
            model.move(direction)
        case .activateSelected:
            model.activateSelected()
        case let .select(number):
            model.select(number: number)
        }
        return true
    }

    private func installDismissHandlers(panel: NSPanel) {
        tokens.removeAll()
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
        ]
        tokens.localMouse = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if event.window === panel,
               !ActionGridPointerActivationPolicy.acceptsPointerEvent(
                   eventUptime: event.timestamp,
                   presentationUptime: self.presentationUptime,
                   source: self.presentationSource
               ) {
                return nil
            }
            return event
        }
        dismissalMonitor.start(
            for: panel,
            isSuspended: { [weak self] in self?.isPresentingConfirmation == true },
            onDismiss: { [weak self] in self?.close(restoringFocus: false) }
        )
    }
}

private struct ActionGridTileLabel: View {
    private enum Layout {
        static let primaryVerticalOffset: CGFloat = -1
        static let primarySpacing: CGFloat = 6
        static let titleHeight: CGFloat = 38
        static let statusHeight: CGFloat = 16
        static let statusBottomPadding: CGFloat = 6
    }

    let entry: ResolvedActionGridEntry
    let isExecuting: Bool

    private var status: String? {
        isExecuting ? FeatureL10n.string("运行中") : entry.tileStatus
    }

    var body: some View {
        ZStack {
            primaryContent
                .offset(y: Layout.primaryVerticalOffset)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.90)
                    .frame(height: Layout.statusHeight)
                    .padding(.bottom, Layout.statusBottomPadding)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
            }
        }
    }

    private var primaryContent: some View {
        VStack(spacing: Layout.primarySpacing) {
            Group {
                if isExecuting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accentColor)
                } else {
                    Image(systemName: PluginSystemImage.resolvedName(entry.systemImage))
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(height: 30)

            Text(entry.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(entry.availability.isAvailable ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .allowsTightening(true)
                .minimumScaleFactor(0.92)
                .frame(height: Layout.titleHeight, alignment: .center)
        }
    }

    private var iconColor: Color {
        guard entry.availability.isAvailable else { return .secondary }
        return entry.presentationState == .active ? .accentColor : .primary
    }

    private var statusColor: Color {
        if isExecuting || entry.presentationState == .active { return .accentColor }
        if !entry.availability.isAvailable { return .orange }
        return .secondary
    }
}

struct ActionGridOverlayRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: ActionGridOverlayModel
    let onDismiss: () -> Void

    var body: some View {
        ActionGridOverlayView(model: model, onDismiss: onDismiss)
            .environment(\.locale, PluginRuntimeLocalization.locale)
            .environment(
                \.layoutDirection,
                Self.layoutDirection(for: PluginRuntimeLocalization.locale)
            )
            .onChange(of: runtimeLocale.revision) { _, _ in
                model.refreshLocalization()
            }
    }

    static func layoutDirection(for locale: Locale) -> LayoutDirection {
        locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

private struct ActionGridOverlayView: View {
    @ObservedObject var model: ActionGridOverlayModel
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var hoveredSlot: Int?

    private var accessibilityPolicy: ActionGridOverlayAccessibilityPolicy {
        ActionGridOverlayAccessibilityPolicy(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            if let navigationTitle = model.navigationTitle {
                HStack {
                    Button {
                        _ = model.navigateBack()
                    } label: {
                        Label(FeatureL10n.string("返回"), systemImage: "chevron.backward")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Text(navigationTitle)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()
                }
            }

            if model.entries.isEmpty {
                emptyFolderView
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(ActionGridOverlayGeometry.tileWidth),
                            spacing: ActionGridOverlayGeometry.gridSpacing
                        ),
                        count: model.columns
                    ),
                    spacing: ActionGridOverlayGeometry.gridSpacing
                ) {
                    ForEach(0 ..< model.slotCount, id: \.self) { slot in
                        if let entry = model.entry(at: slot) {
                            let isExecuting = model.executingEntryID == entry.id
                            Button { model.activate(entry) } label: {
                                ActionGridTileLabel(
                                    entry: entry,
                                    isExecuting: isExecuting
                                )
                                .padding(.horizontal, 10)
                                .frame(
                                    width: ActionGridOverlayGeometry.tileWidth,
                                    height: ActionGridOverlayGeometry.tileHeight
                                )
                                .contentShape(Rectangle())
                                .opacity(tileOpacity(for: entry, isExecuting: isExecuting))
                                .background(tileBackground(
                                    selected: slot == model.selectedIndex,
                                    hovered: hoveredSlot == slot && !model.isExecuting
                                ))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isExecuting)
                            .help(entry.helpText)
                            .onHover { hovering in
                                if hovering {
                                    hoveredSlot = slot
                                } else if hoveredSlot == slot {
                                    hoveredSlot = nil
                                }
                            }
                            .accessibilityLabel(FeatureL10n.joined([String(slot + 1), entry.accessibilityLabel]))
                            .accessibilityValue(isExecuting
                                ? FeatureL10n.string("运行中")
                                : entry.accessibilityValue)
                            .accessibilityHint(entry.accessibilityHint)
                            .accessibilityAddTraits(slot == model.selectedIndex ? .isSelected : [])
                            .accessibilityIdentifier("mactools.action-grid.cell.\(slot + 1)")
                        } else {
                            Color.clear
                                .frame(
                                    width: ActionGridOverlayGeometry.tileWidth,
                                    height: ActionGridOverlayGeometry.tileHeight
                                )
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            if let feedback = model.feedback {
                Label(feedback, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    .help(feedback)
            }
        }
        .padding(ActionGridOverlayGeometry.contentPadding)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    accessibilityPolicy.usesMaterialBackground
                        ? AnyShapeStyle(.regularMaterial)
                        : AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(
                        colorSchemeContrast == .increased ? 0.80 : 0.45
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .animation(
            accessibilityPolicy.animatesSelection ? .easeOut(duration: 0.16) : nil,
            value: model.selectedIndex
        )
        .animation(
            accessibilityPolicy.animatesSelection ? .easeOut(duration: 0.12) : nil,
            value: hoveredSlot
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FeatureL10n.string("操作网格"))
    }

    private var emptyFolderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)

            Text(FeatureL10n.string("此文件夹为空"))
                .font(.headline)

            Text(FeatureL10n.string("在操作网格设置中添加操作。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: ActionGridOverlayGeometry.emptyStateHeight
        )
        .accessibilityElement(children: .combine)
    }

    private func tileBackground(selected: Bool, hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape
            .fill(selected
                ? Color.accentColor.opacity(0.08)
                : Color(nsColor: .controlBackgroundColor).opacity(
                    accessibilityPolicy.usesMaterialBackground && colorSchemeContrast != .increased
                        ? 0.72
                        : 1
                ))
            .overlay {
                if hovered, !selected {
                    shape.fill(Color.primary.opacity(0.045))
                }
            }
            .overlay {
                if selected {
                    shape.strokeBorder(
                        Color.accentColor,
                        lineWidth: colorSchemeContrast == .increased ? 3 : 2
                    )
                }
            }
    }

    private func tileOpacity(
        for entry: ResolvedActionGridEntry,
        isExecuting: Bool
    ) -> Double {
        if model.isExecuting && !isExecuting { return 0.58 }
        return 1
    }
}
