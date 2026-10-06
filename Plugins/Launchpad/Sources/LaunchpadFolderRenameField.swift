import AppKit
import SwiftUI

/// Programmatic handle into the bridged rename field, owned by the grid view (`@State`, so it
/// survives re-renders). SwiftUI-side hooks that must end or start editing — the panel's
/// blank-space tap, `closeFolder`, the in-folder `onDragBegan` (grid cells never take first
/// responder, so blur alone can't end the session), and the context-menu rename — route
/// through it into the live coordinator.
@MainActor
final class LaunchpadFolderRenameController {
    weak var coordinator: LaunchpadFolderRenameField.Coordinator?

    var isEditing: Bool { coordinator?.isEditing ?? false }

    /// Commit (or cancel) the in-flight rename, if any. Safe to call unconditionally.
    func endEditing(commit: Bool) {
        coordinator?.endEditingNow(commit: commit)
    }
}

/// The folder panel's title: a real `NSTextField` bridged into SwiftUI, ALWAYS rendered —
/// it reads as a static title until clicked, then edits inline (macOS-native Launchpad
/// behaviour, design §2.2). One constant NSView sidesteps the Text↔TextField identity swap
/// this ZStack-over-AppKit hierarchy is known to mishandle (see the `folderShown` note), and
/// editing only moves first responder WITHIN the overlay window — no resign-active/key, so
/// the dismiss observers need no new exemptions. Mirrors the `LaunchpadSearchField` bridge:
/// Coordinator + `doCommandBySelector` + `hasMarkedText()` for IME safety.
struct LaunchpadFolderRenameField: NSViewRepresentable {
    @Environment(\.layoutDirection) private var layoutDirection
    var folderID: String
    var name: String
    var placeholder: String
    /// The big-title text colour, derived from the label-colour preset (design 2026-06-13).
    /// Defaults to `.labelColor` — the historical hardcoded title colour — so an unset caller
    /// renders exactly as before.
    var titleColor: NSColor = .labelColor
    /// The big-title font, derived in `LaunchpadGridMetrics.resolve(_:)` (folderTitleFontSize/
    /// folderTitleWeight). The default reproduces the historical `.title2`/semibold title, so an
    /// unset caller is byte-compatible.
    var titleFont: NSFont = .systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize,
        weight: .semibold
    )
    /// Folder id whose field should grab focus + select-all (context-menu rename / the
    /// post-creation auto-open). Consumed via `onFocusRequestHandled`.
    var focusRequestID: String?
    var controller: LaunchpadFolderRenameController?
    /// Refused entry into editing (e.g. mid-carry): the field stays a static title.
    var editGate: @MainActor () -> Bool = { true }
    var onCommit: (String) -> Void
    var onFocusRequestHandled: () -> Void = {}

    /// True when `responder` is a field editor currently editing a rename field — the Esc
    /// key monitor then lets the event through so `cancelOperation` cancels the rename
    /// instead of closing the launcher (design §2.4; the marked-text IME exemption stays
    /// first). Static + responder-typed so the routing rule is unit-testable.
    @MainActor
    static func shouldRouteEsc(to responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView else { return false }
        // The field editor's delegate IS the control being edited (AppKit wiring). Bridge via
        // AnyObject: NSTextField's NSTextViewDelegate conformance is ObjC-dynamic, so a direct
        // `is` reads as an unrelated-type cast to the Swift type checker.
        return (editor.delegate as AnyObject?) is LaunchpadRenameTextField
    }

    /// Placeholder text with a centered paragraph style — a plain `placeholderString` ignores
    /// the field's `.center` alignment and draws leading-aligned.
    private static func centeredPlaceholder(_ text: String, font: NSFont?) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        if let font { attributes[.font] = font }
        return NSAttributedString(string: text, attributes: attributes)
    }

    func makeNSView(context: Context) -> LaunchpadRenameTextField {
        let field = LaunchpadRenameTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        // Label-style injection (design 2026-06-13): colour from the preset, font derived from
        // the folder-title metrics. The defaults reproduce the historical `.labelColor` +
        // `.title2`/semibold title. `updateNSView` MUST re-apply both — this Representable reuses
        // the same field instance, so a preset change after reopen would not refresh otherwise.
        field.textColor = titleColor
        field.font = titleFont
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        // NOT scrollable: a scrollable NSTextFieldCell draws from the leading edge and ignores
        // `.center` alignment, so the title rendered left. Single-line + truncating tail already
        // prevent wrapping, so dropping it keeps the title centered (iOS folder-title parity).
        field.stringValue = name
        // Centered placeholder: a plain `placeholderString` draws leading-aligned regardless of
        // the field's `.center`, so the empty-title prompt rendered left. An attributed string
        // with a centered paragraph style honors the alignment.
        field.placeholderAttributedString = Self.centeredPlaceholder(placeholder, font: field.font)
        field.cell?.baseWritingDirection = .natural
        configureDirectionAndAccessibility(field)
        field.editGate = { [weak coordinator = context.coordinator] in
            coordinator?.parent.editGate() ?? true
        }
        field.onFocusIn = { [weak coordinator = context.coordinator, weak field] in
            coordinator?.beginEditing(original: field?.stringValue ?? "")
        }
        context.coordinator.field = field
        controller?.coordinator = context.coordinator
        return field
    }

    func updateNSView(_ field: LaunchpadRenameTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.field = field
        controller?.coordinator = coordinator
        // Symmetric with `makeNSView`: the Representable reuses the same field across reopens, so
        // re-apply the label style here or a preset change would not take until the panel is
        // recreated. Gate behind a value-changed check (like the `folderID`/`stringValue` guards
        // below) so a re-render mid-rename — `controlTextDidChange` saves every keystroke, which
        // re-renders the parent and fires this on each key — does not churn the live field editor's
        // layout by reassigning an already-equal font/colour. Set the font BEFORE rebuilding the
        // placeholder so it follows (centeredPlaceholder reads `field.font`).
        if field.textColor != titleColor {
            field.textColor = titleColor
        }
        if field.font != titleFont || field.placeholderAttributedString?.string != placeholder {
            field.font = titleFont
            field.placeholderAttributedString = Self.centeredPlaceholder(placeholder, font: field.font)
        }
        configureDirectionAndAccessibility(field)
        if coordinator.folderID != folderID {
            // The panel stayed mounted across a close→reopen of a different folder (the 0.34s
            // unmount grace): any leftover session belongs to the OLD folder — `closeFolder`
            // already committed it, so just drop the state and show the new name.
            coordinator.abandonSession()
            coordinator.folderID = folderID
            field.stringValue = name
        } else if !coordinator.isEditing, field.stringValue != name {
            field.stringValue = name             // reflect store changes; never stomp live typing
        }
        if let request = focusRequestID, request == folderID {
            coordinator.requestProgrammaticFocus()
        }
    }

    private func configureDirectionAndAccessibility(_ field: LaunchpadRenameTextField) {
        let direction: NSUserInterfaceLayoutDirection = layoutDirection == .rightToLeft
            ? .rightToLeft : .leftToRight
        if field.userInterfaceLayoutDirection != direction {
            field.userInterfaceLayoutDirection = direction
            field.cell?.userInterfaceLayoutDirection = direction
        }
        field.setAccessibilityLabel(placeholder)
    }

    /// Unmount backstop, SECOND line of defence: an unresolved session commits so no typed
    /// name is ever lost. The primary paths commit earlier and on the event stack — scrim
    /// close / typing-to-search via `closeFolder`, whole-window teardown via the overlay
    /// controller's `close()` resigning first responder (SwiftUI does NOT contract dismantle
    /// for an NSHostingView deallocated with its window, only for diffing removals). This
    /// catches what remains, e.g. the folder dissolving underneath the open panel. Data only —
    /// the window may be going away, so no refocus.
    static func dismantleNSView(_ field: LaunchpadRenameTextField, coordinator: Coordinator) {
        coordinator.endEditingNow(commit: true, refocus: false)
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Forwards AppKit text-control events into the pure `LaunchpadRenameEditSession` and
    /// applies its resolutions. The handle* methods take plain values so unit tests drive
    /// the full table without a window or field editor.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LaunchpadFolderRenameField
        weak var field: LaunchpadRenameTextField?
        var folderID: String
        private(set) var session: LaunchpadRenameEditSession?
        /// Last applied resolution — test instrumentation for the forwarding table.
        private(set) var lastResolution: LaunchpadRenameEditSession.Resolution?
        private var focusRequestInFlight = false
        /// True once a keystroke has been saved to the store in real time this session, so an Esc
        /// cancel knows it must roll the store back to the original name. Cleared on each begin.
        private var hasLiveCommitted = false

        init(_ parent: LaunchpadFolderRenameField) {
            self.parent = parent
            self.folderID = parent.folderID
        }

        var isEditing: Bool { session.map { !$0.hasResolved } ?? false }

        // MARK: Session events (unit-testable surface)

        func beginEditing(original: String) {
            guard !isEditing else { return }
            session = .begin(originalName: original)
            hasLiveCommitted = false
        }

        func handleTextChange(_ text: String) {
            session?.textChanged(text)
        }

        /// `doCommandBySelector` routing. During IME composition the command belongs to the
        /// candidate window — return false so Return confirms / Esc cancels the composition,
        /// never resolving the rename (same discipline as the search field).
        func handleCommand(_ selector: Selector, hasMarkedText: Bool) -> Bool {
            guard !hasMarkedText, session != nil else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                apply(resolve { $0.commit() })
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                apply(resolve { $0.cancel() })
                return true
            default:
                return false
            }
        }

        /// Native end-editing (blur, refocus after Return/Esc, teardown). The session's latch
        /// makes the post-Return/post-Esc occurrence inert; a plain blur commits here.
        func handleEndEditing() {
            apply(resolve { $0.endEditing() })
            session = nil
        }

        /// SwiftUI-side hooks (blank tap / closeFolder / in-folder drag began).
        func endEditingNow(commit: Bool, refocus: Bool = true) {
            guard isEditing else { return }
            apply(resolve { commit ? $0.commit() : $0.cancel() }, refocus: refocus)
        }

        func detach() {
            session = nil
            field = nil
        }

        func abandonSession() {
            session = nil
        }

        // MARK: Programmatic focus (context-menu rename / post-creation auto-open)

        /// Focus + select-all once the field is actually in a window. The panel may be mounting
        /// in this very SwiftUI transaction, so retry across a few runloop turns before giving
        /// up; the request is consumed (cleared) either way.
        func requestProgrammaticFocus() {
            guard !focusRequestInFlight else { return }
            focusRequestInFlight = true
            attemptProgrammaticFocus(retries: 8)
        }

        private func attemptProgrammaticFocus(retries: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let field = self.field, let window = field.window {
                    self.focusRequestInFlight = false
                    self.parent.onFocusRequestHandled()
                    guard self.parent.editGate() else { return }   // mid-carry: stay a title
                    window.makeFirstResponder(field)
                    field.selectText(nil)                          // programmatic entry selects all (§2.3)
                    // `selectText` re-establishes the field editor and resets its alignment to the
                    // natural (leading) default, stomping the `.center` that becomeFirstResponder /
                    // controlTextDidBeginEditing applied — so the auto-opened (post-creation) and
                    // context-menu-rename titles rendered LEFT-aligned while the click-entered and
                    // static titles centered. Re-apply center AFTER selectText, where the editor is
                    // guaranteed live. (Runtime-verified: without this, a new folder's title sits
                    // ~one-cell left of the panel centre.)
                    (field.currentEditor() as? NSTextView)?.alignment = .center
                } else if retries > 0 {
                    self.attemptProgrammaticFocus(retries: retries - 1)
                } else {
                    self.focusRequestInFlight = false
                    self.parent.onFocusRequestHandled()
                }
            }
        }

        // MARK: Resolution plumbing

        private func resolve(
            _ event: (inout LaunchpadRenameEditSession) -> LaunchpadRenameEditSession.Resolution?
        ) -> LaunchpadRenameEditSession.Resolution? {
            guard var current = session else { return nil }
            let resolution = event(&current)
            session = current                    // keep the latched session until end-editing clears it
            return resolution
        }

        private func apply(_ resolution: LaunchpadRenameEditSession.Resolution?, refocus: Bool = true) {
            guard let resolution else { return }
            lastResolution = resolution
            switch resolution {
            case .commit(let text):
                parent.onCommit(text)
            case .cancel(let restore):
                field?.stringValue = restore
                // Only roll the store back if real-time save actually wrote mid-edit text this
                // session; otherwise a cancel must stay silent (no spurious commit).
                if hasLiveCommitted {
                    parent.onCommit(restore)
                }
            }
            // Hand the keyboard back to the search field (Return keeps the folder open, §2.3);
            // the resulting native end-editing is latched into a no-op by the session.
            if refocus { refocusSearchField() }
        }

        private func refocusSearchField() {
            guard let window = field?.window,
                  let search = Self.searchField(in: window.contentView) else { return }
            window.makeFirstResponder(search)
        }

        private static func searchField(in view: NSView?) -> NSSearchField? {
            guard let view else { return nil }
            if let field = view as? NSSearchField { return field }
            for subview in view.subviews {
                if let found = searchField(in: subview) { return found }
            }
            return nil
        }

        // MARK: NSTextFieldDelegate

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Center the shared field editor here, where it is guaranteed attached — doing it in
            // becomeFirstResponder is too early (currentEditor() may still be nil), which left the
            // caret/placeholder leading-aligned while editing despite the field's .center.
            (field?.currentEditor() as? NSTextView)?.alignment = .center
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            handleTextChange(field.stringValue)
            // Real-time save: persist every keystroke so the name can never be lost to a focus
            // race or an out-of-order close (the auto-open rename and the carry-release refocus
            // can land in the same runloop). `renameFolder` trims, falls back on empty, and
            // no-op-guards unchanged names, so high-frequency calls are cheap and safe. An Esc
            // cancel rolls the store back to the original name (see `apply`).
            if isEditing {
                parent.onCommit(field.stringValue)
                hasLiveCommitted = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            handleEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            handleCommand(selector, hasMarkedText: textView.hasMarkedText())
        }
    }
}

/// NSTextField subclass so the Esc monitor can recognise the rename field editor by delegate
/// type, and so entry into editing can be gated (mid-carry the title must stay inert).
final class LaunchpadRenameTextField: NSTextField {
    var editGate: @MainActor () -> Bool = { true }
    var onFocusIn: @MainActor () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        guard editGate() else { return false }
        let became = super.becomeFirstResponder()
        if became {
            // The shared field editor does not inherit the field's `.center` alignment, so typed
            // text would left-align while editing; force it center to match the static title.
            (currentEditor() as? NSTextView)?.alignment = .center
            onFocusIn()
        }
        return became
    }
}
