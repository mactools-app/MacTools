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
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return setting(value, in: reference)
    }

    public static func title(_ title: String, target: String? = nil, value: Int) -> String {
        let percent = (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
        return [title, target, percent].compactMap { $0 }.joined(separator: " · ")
    }

    static var fieldTitle: String {
        PluginKitLocalization.string("action.percentage.title", defaultValue: "目标百分比")
    }
}

public struct ActionPercentageField: View {
    @Binding private var text: String
    @FocusState private var isFocused: Bool
    private let autofocus: Bool

    public init(text: Binding<String>, autofocus: Bool = false) {
        _text = text
        self.autofocus = autofocus
    }

    public var body: some View {
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
    private let onSave: (ActionReference) -> Void

    @State private var text: String

    public init(
        title: String,
        template: ActionReference,
        current: ActionReference?,
        cancelTitle: String,
        saveTitle: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ActionReference) -> Void
    ) {
        self.title = title
        self.template = template
        self.cancelTitle = cancelTitle
        self.saveTitle = saveTitle
        self.onCancel = onCancel
        self.onSave = onSave
        let selected = current.flatMap { ActionPercentage.template(for: $0) == template ? $0 : nil }
        _text = State(initialValue: String(ActionPercentage.value(in: selected ?? template) ?? ActionPercentage.defaultValue))
    }

    public var body: some View {
        let reference = ActionPercentage.setting(text, in: template)
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Text(title)
                .font(PluginSettingsTheme.Typography.sectionTitle)

            ActionPercentageField(text: $text, autofocus: true)

            HStack {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button(saveTitle) {
                    if let reference { onSave(reference) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(reference == nil)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }
}
