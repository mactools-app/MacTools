import SwiftUI
import MacToolsPluginKit

extension PluginPanelControl {
    func selectingNavigationOption(_ optionID: String?) -> Self {
        Self(id: id, kind: kind, options: options, selectedOptionID: optionID,
             dateValue: dateValue, minimumDate: minimumDate, displayedComponents: displayedComponents,
             datePickerStyle: datePickerStyle, sectionTitle: sectionTitle,
             sliderValue: sliderValue, sliderBounds: sliderBounds, sliderStep: sliderStep, valueLabel: valueLabel,
             actionTitle: actionTitle, actionIconSystemName: actionIconSystemName,
             actionBehavior: actionBehavior, showsLeadingDivider: showsLeadingDivider, isEnabled: isEnabled)
    }
}

// Host projections carry placement identity; plugin declarations remain in PluginKit.
struct PluginPanelWidgetViewItem: Identifiable {
    let id: String
    let content: AnyView

    init(id: String, content: AnyView) {
        self.id = id
        self.content = content
    }
}

struct PluginPanelWidgetSnapshot: Identifiable {
    let id: String
    let pluginID: String
    let title: String
    let iconName: String
    let iconTint: Color
    let description: String
    let helpText: String
    let descriptionTone: PluginPanelDescriptionTone
    let span: PluginPanelWidgetSpan
    let isActive: Bool
    let isEnabled: Bool

    init(
        id: String,
        title: String,
        iconName: String,
        iconTint: Color,
        description: String,
        helpText: String,
        descriptionTone: PluginPanelDescriptionTone,
        span: PluginPanelWidgetSpan,
        isActive: Bool,
        isEnabled: Bool,
        pluginID: String? = nil
    ) {
        self.id = id
        self.pluginID = pluginID ?? id
        self.title = title
        self.iconName = iconName
        self.iconTint = iconTint
        self.description = description
        self.helpText = helpText
        self.descriptionTone = descriptionTone
        self.span = span
        self.isActive = isActive
        self.isEnabled = isEnabled
    }
}


struct PluginPanelRowSnapshot: Identifiable {
    let id: String
    let pluginID: String
    let title: String
    let iconName: String
    let iconTint: Color
    let controlStyle: PluginControlStyle
    let menuActionBehavior: PluginMenuActionBehavior
    let description: String
    let helpText: String
    let descriptionTone: PluginPanelDescriptionTone
    let isOn: Bool
    let isExpanded: Bool
    let isEnabled: Bool
    let detail: PluginPanelDetail?
    let buttonActionID: String?
    let buttonTitle: String?
    let supportsCompactSwitch: Bool
    let usesCompactPresentation: Bool
    let width: MenuBarPanelItemWidth?

    init(
        id: String,
        title: String,
        iconName: String,
        iconTint: Color,
        controlStyle: PluginControlStyle,
        menuActionBehavior: PluginMenuActionBehavior,
        description: String,
        helpText: String,
        descriptionTone: PluginPanelDescriptionTone,
        isOn: Bool,
        isExpanded: Bool,
        isEnabled: Bool,
        detail: PluginPanelDetail?,
        buttonActionID: String?,
        buttonTitle: String?,
        pluginID: String? = nil,
        supportsCompactSwitch: Bool = false,
        usesCompactPresentation: Bool = false,
        width: MenuBarPanelItemWidth? = nil
    ) {
        self.id = id
        self.pluginID = pluginID ?? id
        self.title = title
        self.iconName = iconName
        self.iconTint = iconTint
        self.controlStyle = controlStyle
        self.menuActionBehavior = menuActionBehavior
        self.description = description
        self.helpText = helpText
        self.descriptionTone = descriptionTone
        self.isOn = isOn
        self.isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.detail = detail
        self.buttonActionID = buttonActionID
        self.buttonTitle = buttonTitle
        self.supportsCompactSwitch = supportsCompactSwitch
        self.usesCompactPresentation = usesCompactPresentation
        self.width = width
    }
}
