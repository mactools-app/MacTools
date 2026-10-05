import AppKit
import MacToolsPluginKit
import SwiftUI

/// A real `NSSearchField` bridged into SwiftUI.
///
/// Using a real text control (not root-view `keyDown` interception) is what makes
/// search + keyboard navigation IME-safe (Codex P0 #2/#3): during CJK composition the
/// system routes arrows/Return to the candidate window and does NOT call
/// `doCommandBySelector`, so we never hijack a candidate-selection Return to launch an
/// app. Arrow/Return/Esc are handled via `doCommandBySelector`; plain + composed
/// characters flow into the field naturally.
struct LaunchpadSearchField: NSViewRepresentable {
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var text: String
    var localization: PluginLocalization = PluginLocalization(bundle: .main)
    var onMove: (MoveDirection) -> Void
    var onLaunch: () -> Void
    var onCancel: () -> Void

    enum MoveDirection { case left, right, up, down }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.placeholderString = localization.string("search.placeholder", defaultValue: "搜索应用")
        field.alignment = .natural
        field.cell?.baseWritingDirection = .natural
        configureDirectionAndAccessibility(field)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        // Focus so typing/IME works immediately while the grid stays visible.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = localization.string("search.placeholder", defaultValue: "搜索应用")
        configureDirectionAndAccessibility(nsView)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func configureDirectionAndAccessibility(_ field: NSSearchField) {
        let direction: NSUserInterfaceLayoutDirection = layoutDirection == .rightToLeft
            ? .rightToLeft : .leftToRight
        if field.userInterfaceLayoutDirection != direction {
            field.userInterfaceLayoutDirection = direction
            field.cell?.userInterfaceLayoutDirection = direction
        }
        field.setAccessibilityLabel(field.placeholderString)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LaunchpadSearchField
        init(_ parent: LaunchpadSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Belt-and-suspenders for IME (Codex P1): if there's marked (composing) text,
            // hand the command back to the system so arrows pick candidates and Return
            // confirms composition — never navigate/launch mid-composition.
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):  parent.onMove(.left);  return true
            case #selector(NSResponder.moveRight(_:)): parent.onMove(.right); return true
            case #selector(NSResponder.moveUp(_:)):    parent.onMove(.up);    return true
            case #selector(NSResponder.moveDown(_:)):  parent.onMove(.down);  return true
            case #selector(NSResponder.insertNewline(_:)): parent.onLaunch(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
