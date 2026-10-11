import AppKit
import SwiftUI
import MacToolsPluginKit

@MainActor
final class CalendarEventPopoverController<Content: View>: NSViewController {
    private let hostingController: NSHostingController<CalendarEventPopoverLocalizedRoot<Content>>
    private let theme: PluginComponentTheme
    private var contentSize = NSSize.zero

    init(content: Content, theme: PluginComponentTheme) {
        hostingController = NSHostingController(rootView: CalendarEventPopoverLocalizedRoot(content: content))
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = CalendarEventPopoverBackgroundView(theme: theme)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        let content = hostingController.view
        contentSize = NSSize(width: 230, height: min(content.fittingSize.height, 260))
        // Measure before disabling intrinsic sizing. The container then owns the
        // size so SwiftUI cannot resize the shown popover a second time.
        hostingController.sizingOptions = []
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // Only the background extends into the attachment arrow and rounded edges.
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            content.topAnchor.constraint(equalTo: safeArea.topAnchor),
            content.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }

    var popoverSize: NSSize {
        loadViewIfNeeded()
        let insets = view.safeAreaInsets
        let hasInsets = insets.top + insets.bottom + insets.left + insets.right > 0
        // AppKit supplies live insets after presentation. Match its initial chrome
        // allowance until then, preserving the existing 230-point content width.
        return NSSize(
            width: contentSize.width + (hasInsets ? insets.left + insets.right : 26),
            height: contentSize.height + (hasInsets ? insets.top + insets.bottom : 26)
        )
    }
}

private struct CalendarEventPopoverLocalizedRoot<Content: View>: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let content: Content

    init(content: Content) { self.content = content }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        content
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

private final class CalendarEventPopoverBackgroundView: NSView {
    private let theme: PluginComponentTheme

    init(theme: PluginComponentTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Card colors can be translucent. Composite them over the panel surface
        // once, across both the body and arrow, instead of tinting only the body.
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor(theme.surfaces.panel).setFill()
        dirtyRect.fill()
        NSColor(theme.surfaces.card).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
