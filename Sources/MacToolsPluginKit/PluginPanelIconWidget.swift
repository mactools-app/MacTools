import SwiftUI

/// The primary interaction of a compact icon widget, independent of row layout.
public enum PluginPanelIconControl: Equatable, Sendable {
    case toggle
    case button

    func action(isOn: Bool, requestedToggleValue: Bool? = nil) -> PluginPanelAction {
        switch self {
        case .toggle: .setSwitch(requestedToggleValue ?? !isOn)
        case .button: .invokeAction(controlID: "execute")
        }
    }
}

public extension PluginPanelItem {
    /// An optional, library-only shortcut to a row with one primary control and no detail actions.
    /// Reads the same snapshot and invokes the same handler without owning state.
    static func iconWidget(
        id: String,
        title: String,
        systemImage: String,
        control: PluginPanelIconControl,
        state: PluginPanelRowState,
        menuActionBehavior: PluginMenuActionBehavior,
        action: @escaping (PluginPanelAction) -> Void
    ) -> Self {
        .widget(
            id: id,
            title: title,
            systemImage: systemImage,
            descriptor: PluginPanelIconWidget.descriptor,
            state: PluginPanelWidgetState(
                subtitle: state.subtitle,
                isActive: control == .toggle && state.isOn,
                isEnabled: state.isEnabled,
                isAvailable: state.isAvailable,
                errorMessage: state.errorMessage
            )
        ) { context in
            PluginPanelIconWidget(
                title: title, systemImage: systemImage, control: control,
                state: state, context: context,
                menuActionBehavior: menuActionBehavior, action: action
            )
        }
    }
}

/// Fixed geometry avoids measurement tasks and keeps mixed widget grids stable.
@MainActor
struct PluginPanelIconWidget: View {
    /// Shared icon, title, and hit-target geometry for every plugin.
    enum Layout {
        static let height = PluginPanelWidgetLayoutMetrics.default.compactCellSize.height
        static let iconSize: CGFloat = 42
        static let symbolSize: CGFloat = 20
        static let buttonCornerRadius: CGFloat = 13
        static let titleSpacing: CGFloat = 4
        static let titleHeight: CGFloat = 14
    }

    static let height = Layout.height
    static let descriptor = PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(
        width: 1,
        height: PluginPanelWidgetLayoutMetrics.default.heightSpan(fittingContentHeight: height),
        grid: .compact
    )!)

    let title: String
    let systemImage: String
    let control: PluginPanelIconControl
    let state: PluginPanelRowState
    let context: PluginPanelWidgetContext
    let menuActionBehavior: PluginMenuActionBehavior
    let action: (PluginPanelAction) -> Void

    @Environment(\.pluginComponentTheme) private var theme
    @StateObject private var dispatcher = PluginPanelIconActionDispatcher()
    @State private var isHovered = false

    private var isOn: Bool { control == .toggle && state.isOn }
    private var isEnabled: Bool { state.isEnabled && state.isAvailable && !dispatcher.isDispatching }
    private var helpText: String { Self.helpText(title: title, state: state) }

    static func helpText(title: String, state: PluginPanelRowState) -> String {
        var lines: [String] = []
        for value in [title, state.subtitle, state.errorMessage].compactMap({ $0 }) {
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !lines.contains(line) { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Button { activate() } label: {
            VStack(spacing: Layout.titleSpacing) {
                icon
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.titleHeight)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height, alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: PluginPanelWidgetLayoutMetrics.cardCornerRadius))
        }
        .buttonStyle(PluginPanelIconButtonStyle())
        .disabled(!isEnabled)
        .allowsHitTesting(!context.isPreview)
        .onHover { isHovered = $0 }
        .help(helpText)
        .overlay(alignment: .topTrailing) {
            if state.errorMessage != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.status.warning)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityRepresentation {
            if control == .toggle {
                Toggle(title, isOn: Binding(get: { isOn }, set: { activate(toggleValue: $0) }))
                    .toggleStyle(.switch)
                    .disabled(!isEnabled || context.isPreview)
                    .help(helpText)
            } else {
                Button(title) { activate() }
                    .disabled(!isEnabled || context.isPreview)
                    .help(helpText)
            }
        }
    }

    private var icon: some View {
        let shape = RoundedRectangle(
            cornerRadius: control == .toggle ? Layout.iconSize / 2 : Layout.buttonCornerRadius,
            style: .continuous
        )
        return ZStack {
            shape.fill(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(
                isEnabled && isHovered ? theme.surfaces.controlHover : theme.surfaces.control
            ))
            Image(systemName: PluginSystemImage.resolvedName(systemImage))
                .font(.system(size: Layout.symbolSize, weight: .medium))
                .symbolRenderingMode(.monochrome)
                // The host resolves its accent against this panel color, so the
                // inverse icon stays legible in light, dark, and imported themes.
                .foregroundStyle(isOn ? theme.surfaces.panel : theme.text.primary)
                .frame(width: Layout.iconSize, height: Layout.iconSize, alignment: .center)
        }
        .frame(width: Layout.iconSize, height: Layout.iconSize)
    }

    private func activate(toggleValue: Bool? = nil) {
        dispatcher.perform(control: control, state: state, context: context,
                           behavior: menuActionBehavior, requestedToggleValue: toggleValue, action: action)
    }
}

/// Retains a pending action across view removal and rejects duplicate activation.
@MainActor
final class PluginPanelIconActionDispatcher: ObservableObject {
    @Published private(set) var isDispatching = false

    func perform(control: PluginPanelIconControl, state: PluginPanelRowState,
                 context: PluginPanelWidgetContext, behavior: PluginMenuActionBehavior,
                 requestedToggleValue: Bool? = nil,
                 action: @escaping (PluginPanelAction) -> Void) {
        guard state.isEnabled, state.isAvailable, !context.isPreview, !isDispatching else { return }
        let invocation = control.action(isOn: state.isOn, requestedToggleValue: requestedToggleValue)
        switch behavior {
        case .keepPresented:
            action(invocation)
        case .dismissBeforeHandling:
            isDispatching = true
            context.dismiss()
            // Keep the requested action alive after dismissal unmounts the view.
            Task { @MainActor in
                await Task.yield()
                action(invocation)
                self.isDispatching = false
            }
        }
    }
}

private struct PluginPanelIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
