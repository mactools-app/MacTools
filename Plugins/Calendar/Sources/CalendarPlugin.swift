import AppKit
import SwiftUI
import MacToolsPluginKit

public final class CalendarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        CalendarPluginProvider(context: context)
    }
}

@MainActor
private struct CalendarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let resourceContext = PluginRuntimeContext(
            pluginID: context.pluginID,
            resourceBundle: context.resourceBundle,
            resourceSubdirectory: "CalendarPluginResources",
            storage: context.storage,
            supportDirectory: context.supportDirectory,
            cacheDirectory: context.cacheDirectory,
            temporaryDirectory: context.temporaryDirectory
        )
        return [CalendarPlugin(context: resourceContext, localization: localization)]
    }
}

@MainActor
final class CalendarPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    private enum PermissionID {
        static let calendarEvents = "calendar-events"
        static let calendarAutomation = "calendar-automation"
    }

    private enum ControlID {
        static let weekStartDay = "week-start-day"
        static let showsRecentAgenda = "show-recent-agenda"
        static let agendaDirection = "agenda-direction"
        static let agendaDayCount = "agenda-day-count"
        static let alternateCalendar = "alternate-calendar"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "calendar",
            title: localization.string("metadata.title", defaultValue: "日历"),
            iconName: "calendar",
            iconTint: Color(nsColor: .systemIndigo),
            order: 15,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看日期、节假日和系统日程"
            )
        )
    }

    var descriptor: PluginPanelWidgetDescriptor {
        PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(
                width: 4,
                height: componentSpanHeight
            )!
        )
    }

    private let context: PluginRuntimeContext
    private let eventService: CalendarEventServicing
    private let localization: PluginLocalization
    private let settingsStore: CalendarSettingsStore
    private let viewModel: CalendarComponentViewModel
    private var measuredComponentSpanHeight: Int?

    private var componentSpanHeight: Int {
        measuredComponentSpanHeight ?? PluginPanelWidgetLayoutMetrics.default.heightSpan(
            fittingContentHeight: CalendarComponentLayout.estimatedContentHeight(
                showsRecentAgenda: settingsStore.showsRecentAgenda && viewModel.hasAgendaContent,
                dayCount: viewModel.agendaDays.count,
                eventCount: viewModel.agendaDays.reduce(0) { $0 + $1.events.count }
            )
        )
    }

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(
            pluginID: "calendar",
            resourceSubdirectory: "CalendarPluginResources"
        ),
        eventService: CalendarEventServicing? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.context = context
        self.localization = localization
        self.eventService = eventService ?? CalendarEventService(localization: localization)
        self.settingsStore = CalendarSettingsStore(storage: context.storage)
        self.viewModel = CalendarComponentViewModel(
            eventService: self.eventService,
            holidayProvider: .bundled(context: context),
            calendar: CalendarComponentCalendars.gregorian(
                firstWeekday: self.settingsStore.weekStartDay.calendarFirstWeekday
            ),
            localization: localization,
            agendaRange: self.settingsStore.agendaRange,
            showsRecentAgenda: self.settingsStore.showsRecentAgenda,
            alternateCalendar: self.settingsStore.alternateCalendar,
            calendarProvider: { CalendarComponentCalendars.gregorian() }
        )
        self.viewModel.onStateChange = { [weak self] in self?.onStateChange?() }
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: metadata.defaultDescription,
            isActive: false,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.calendarEvents,
                kind: .calendarFullAccess,
                title: localization.string("permission.events.title", defaultValue: "系统日历事件"),
                description: localization.string(
                    "permission.events.description",
                    defaultValue: "读取系统日历事件，用于在日历组件中显示当天日程。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.calendarAutomation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "定位系统日历"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "点击日期时需要控制系统日历应用，打开并定位到对应日期。"
                )
            )
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "calendar-display",
                    title: localization.string("settings.display.title", defaultValue: "日历显示"),
                    systemImage: "calendar",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.weekStartDay,
                            title: localization.string("settings.weekStart.title", defaultValue: "每周起始日"),
                            description: localization.string(
                                "settings.weekStart.description",
                                defaultValue: "选择月历每周显示的第一天。"
                            ),
                            control: .picker(
                                selectionID: settingsStore.weekStartDay.rawValue,
                                options: CalendarWeekStartDay.allCases.map {
                                    PluginSettingsOption(id: $0.rawValue, title: $0.displayName())
                                },
                                style: .menu
                            )
                        ),
                        PluginSettingsRow(
                            id: ControlID.alternateCalendar,
                            title: localization.string("settings.alternateCalendar.title", defaultValue: "其他历法"),
                            description: localization.string(
                                "settings.alternateCalendar.description", defaultValue: "在公历日期旁显示所选历法。"
                            ),
                            control: .picker(
                                selectionID: settingsStore.alternateCalendar.rawValue,
                                options: CalendarAlternateCalendar.allCases.map {
                                    PluginSettingsOption(id: $0.rawValue, title: $0.title(localization: localization))
                                },
                                style: .menu
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "calendar-agenda",
                    title: localization.string("agenda.title", defaultValue: "近期日程"),
                    systemImage: "calendar.badge.clock",
                    rows: agendaSettingsRows
                )
            ]
        )
    }

    private var agendaSettingsRows: [PluginSettingsRow] {
        [
            PluginSettingsRow(
                id: ControlID.showsRecentAgenda,
                title: localization.string("settings.agenda.show", defaultValue: "显示近期日程"),
                description: localization.string(
                    "settings.agenda.description", defaultValue: "在月历下方按日期查看日程。"
                ),
                control: .toggle(isOn: settingsStore.showsRecentAgenda)
            ),
            PluginSettingsRow(
                id: ControlID.agendaDirection,
                title: localization.string("settings.agenda.direction", defaultValue: "时间范围"),
                isEnabled: settingsStore.showsRecentAgenda,
                control: .picker(
                    selectionID: settingsStore.agendaRange.direction.rawValue,
                    options: CalendarAgendaDirection.allCases.map {
                        PluginSettingsOption(id: $0.rawValue, title: $0.title(localization: localization))
                    },
                    style: .segmented
                )
            ),
            PluginSettingsRow(
                id: ControlID.agendaDayCount,
                title: localization.string("settings.agenda.dayCount", defaultValue: "显示天数"),
                description: localization.string(
                    "settings.agenda.daysDescription", defaultValue: "包含今天，双向范围以今天为中心。"
                ),
                isEnabled: settingsStore.showsRecentAgenda,
                control: .picker(
                    selectionID: String(settingsStore.agendaRange.dayCount),
                    options: (1...7).map {
                        PluginSettingsOption(
                            id: String($0),
                            title: $0 == 1
                                ? localization.string("settings.agenda.oneDay", defaultValue: "1 天")
                                : localization.format("settings.agenda.days", defaultValue: "%d 天", $0)
                        )
                    },
                    style: .menu
                )
            )
        ]
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            CalendarComponentView(
                context: context,
                viewModel: viewModel,
                settingsStore: settingsStore,
                localization: localization,
                onRequestAccess: { [weak self] in
                    self?.handleCalendarEventsPermissionAction()
                },
                onContentHeightChange: { [weak self] height in
                    guard !context.isPreview else { return }
                    self?.componentContentHeightDidChange(height)
                }
            )
        )
    }

    func componentContentHeightDidChange(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }

        let spanHeight = PluginPanelWidgetLayoutMetrics.default.heightSpan(fittingContentHeight: height)
        guard spanHeight != measuredComponentSpanHeight else { return }
        measuredComponentSpanHeight = spanHeight
        onStateChange?()
    }

    func refresh() { viewModel.refreshIfVisible() }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        viewModel.start()
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        viewModel.stop()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.calendarEvents:
            return calendarEventsPermissionState
        case PermissionID.calendarAutomation:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.automation.footnote",
                    defaultValue: "首次定位系统日历时 macOS 会请求控制“日历”的权限；若曾拒绝，请在系统设置的自动化中允许。"
                ),
                statusText: localization.string("permission.automation.status", defaultValue: "按需确认"),
                statusSystemImage: "cursorarrow.click.2",
                statusTone: .neutral
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.calendarEvents:
            handleCalendarEventsPermissionAction()
        case PermissionID.calendarAutomation:
            openPrivacyPane(anchor: "Privacy_Automation")
        default:
            break
        }
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setSelection(controlID, optionID) where controlID == ControlID.alternateCalendar:
            guard let display = CalendarAlternateCalendar(rawValue: optionID) else { return }
            settingsStore.setAlternateCalendar(display)
            // Keep a valid measurement when the date presentation changes without resizing the content.
            viewModel.setAlternateCalendar(display)
            onStateChange?()
        case let .setSelection(controlID, optionID) where controlID == ControlID.weekStartDay:
            guard let day = CalendarWeekStartDay(rawValue: optionID) else {
                return
            }
            setWeekStartDay(day)
        case let .setBoolean(controlID, value) where controlID == ControlID.showsRecentAgenda:
            guard settingsStore.showsRecentAgenda != value else { return }
            settingsStore.setShowsRecentAgenda(value)
            updateAgendaConfiguration()
        case let .setSelection(controlID, optionID) where controlID == ControlID.agendaDirection:
            guard let direction = CalendarAgendaDirection(rawValue: optionID) else { return }
            settingsStore.setAgendaRange(CalendarAgendaRange(
                dayCount: settingsStore.agendaRange.dayCount, direction: direction
            ))
            updateAgendaConfiguration()
        case let .setSelection(controlID, optionID) where controlID == ControlID.agendaDayCount:
            guard let dayCount = Int(optionID), (1...7).contains(dayCount) else { return }
            settingsStore.setAgendaRange(CalendarAgendaRange(
                dayCount: dayCount, direction: settingsStore.agendaRange.direction
            ))
            updateAgendaConfiguration()
        default:
            break
        }
    }
    func handleShortcutAction(id: String) {}

    private func updateAgendaConfiguration() {
        measuredComponentSpanHeight = nil
        viewModel.configureAgenda(range: settingsStore.agendaRange, isVisible: settingsStore.showsRecentAgenda)
        onStateChange?()
    }

    private func setWeekStartDay(_ day: CalendarWeekStartDay) {
        settingsStore.setWeekStartDay(day)
        viewModel.setWeekStartDay(day)
        onStateChange?()
    }

    private var calendarEventsPermissionState: PluginPermissionState {
        switch eventService.authorization {
        case .fullAccess:
            return PluginPermissionState(isGranted: true, footnote: nil)
        case .notDetermined:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.events.notDetermined",
                    defaultValue: "点击请求授权后，系统会询问是否允许读取日历事件。"
                )
            )
        case let .denied(message):
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.format(
                    "permission.events.denied",
                    defaultValue: "%@。可在系统设置的日历隐私项中重新允许。",
                    message
                )
            )
        }
    }

    private func handleCalendarEventsPermissionAction() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let authorization = await eventService.requestAccess()
            if case .denied = authorization {
                openPrivacyPane(anchor: "Privacy_Calendars")
            }
            viewModel.refreshIfVisible()
            onStateChange?()
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
