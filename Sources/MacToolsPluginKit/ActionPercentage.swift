import Foundation
import SwiftUI

/// Opts an action into percentage editing in action pickers. Providers publish a
/// concrete reference at the default value for each target and accept 0 through 100.
public enum ActionPercentage {
    public static let parameterID = "target-percentage"
    public static let defaultValue = 50

    public static var parameter: ActionParameterDefinition {
        ActionParameterDefinition(id: parameterID, title: fieldTitle, kind: .integer)
    }

    public static func value(in reference: ActionReference) -> Int? {
        guard case let .integer(value)? = reference.parameters[parameterID],
              (0...100).contains(value) else { return nil }
        return Int(value)
    }

    public static func template(for reference: ActionReference) -> ActionReference? {
        setting(defaultValue, in: reference)
    }

    public static func setting(_ value: Int, in reference: ActionReference) -> ActionReference? {
        guard self.value(in: reference) != nil, (0...100).contains(value) else { return nil }
        var values = Dictionary(uniqueKeysWithValues: reference.parameters.entries.map { ($0.name, $0.value) })
        values[parameterID] = .integer(Int64(value))
        guard let parameters = try? ActionParameterSet(values) else { return nil }
        return ActionReference(key: reference.key, schemaVersion: reference.schemaVersion, parameters: parameters)
    }

    public static func setting(_ text: String, in reference: ActionReference) -> ActionReference? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).map { character in
            if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }),
               let digit = character.wholeNumberValue {
                return String(digit)
            }
            return String(character)
        }.joined()
        guard let value = Int(normalized) else { return nil }
        return setting(value, in: reference)
    }

    public static func label(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    public static func title(_ title: String, target: String? = nil, value: Int) -> String {
        [title, target, label(value)].compactMap { $0 }.joined(separator: " · ")
    }

    public static func rangeHint(
        for template: ActionReference,
        availability: (ActionReference) -> ActionAvailability
    ) -> String? {
        guard let minimum = setting(0, in: template) else { return nil }
        return availability(minimum).reason
    }

    static var fieldTitle: String {
        PluginKitLocalization.string("action.percentage.title", defaultValue: "目标百分比")
    }
}

public struct ActionPercentageField: View {
    @Binding private var text: String
    @FocusState private var isFocused: Bool
    private let autofocus: Bool
    private let hint: String?

    public init(text: Binding<String>, autofocus: Bool = false, hint: String? = nil) {
        _text = text
        self.autofocus = autofocus
        self.hint = hint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(ActionPercentage.fieldTitle)
                TextField(ActionPercentage.fieldTitle, text: $text, prompt: Text("0–100"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .frame(width: 64)
                    .accessibilityIdentifier("mactools.action.percentage")
                Text("%")
                    .accessibilityHidden(true)
            }
            if let hint {
                Text(hint)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .onAppear { if autofocus { isFocused = true } }
    }
}

public struct ActionPercentageEditor: View {
    private let title: String
    private let template: ActionReference
    private let cancelTitle: String
    private let saveTitle: String
    private let onCancel: () -> Void
    private let availability: (ActionReference) -> ActionAvailability
    private let onSave: (ActionReference) -> Void

    @State private var text: String

    public init(
        title: String,
        template: ActionReference,
        current: ActionReference?,
        cancelTitle: String,
        saveTitle: String,
        availability: @escaping (ActionReference) -> ActionAvailability = { _ in .available },
        onCancel: @escaping () -> Void,
        onSave: @escaping (ActionReference) -> Void
    ) {
        self.title = title
        self.template = template
        self.cancelTitle = cancelTitle
        self.saveTitle = saveTitle
        self.availability = availability
        self.onCancel = onCancel
        self.onSave = onSave
        let selected = current.flatMap { ActionPercentage.template(for: $0) == template ? $0 : nil }
        _text = State(initialValue: String(ActionPercentage.value(in: selected ?? template) ?? ActionPercentage.defaultValue))
    }

    public var body: some View {
        let reference = ActionPercentage.setting(text, in: template)
        let canSave = reference.map { availability($0).isAvailable } == true
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Text(title)
                .font(PluginSettingsTheme.Typography.sectionTitle)

            ActionPercentageField(
                text: $text,
                autofocus: true,
                hint: reference.flatMap { availability($0).reason }
                    ?? ActionPercentage.rangeHint(for: template, availability: availability)
            )

            HStack {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button(saveTitle) {
                    if let reference, canSave { onSave(reference) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }
}
