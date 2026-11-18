import AppKit
import Foundation

/// Configurable appearance for the floating lyrics window.
struct LyricsAppearance: Equatable {
    var fontSize: Double
    var backgroundOpacity: Double
    var textOpacity: Double
    var cornerRadius: Double
    var showsNextLine: Bool
    var textColor: LyricsTextColorOption
    var allowsDragging: Bool
    var karaokeEnabled: Bool

    static let `default` = LyricsAppearance(
        fontSize: 24,
        backgroundOpacity: 0.65,
        textOpacity: 1.0,
        cornerRadius: 16,
        showsNextLine: true,
        textColor: .system,
        allowsDragging: false,
        karaokeEnabled: true
    )
}

enum LyricsTextColorOption: String, CaseIterable, Sendable {
    case system
    case white
    case black

    /// Base color for supporting labels. The frosted-glass background uses the
    /// `.hudWindow` material, which is always dark, so light text is preferred
    /// for the `system` and `white` options.
    var color: NSColor {
        switch self {
        case .system, .white:
            return .white
        case .black:
            return .black
        }
    }

    /// Color for words already sung. Uses the full text color.
    var sungColor: NSColor {
        switch self {
        case .system, .white:
            return .white
        case .black:
            return .black
        }
    }

    /// Color for words not yet sung. Uses a strongly dimmed variant so the
    /// karaoke progress is unmistakable while keeping text faintly legible.
    var upcomingColor: NSColor {
        switch self {
        case .system, .white:
            return .white.withAlphaComponent(0.18)
        case .black:
            return .black.withAlphaComponent(0.18)
        }
    }

    /// Color for already-sung words, scaled by the configured text opacity.
    /// The opacity multiplies the base color so lowering `textOpacity` dims
    /// both sung and upcoming text proportionally while keeping the karaoke
    /// contrast intact.
    func sungColor(opacity: Double) -> NSColor {
        sungColor.withAlphaComponent(opacity)
    }

    /// Color for not-yet-sung words, scaled by the configured text opacity.
    /// The `0.18` base alpha is multiplied by `opacity` (rather than replaced)
    /// so upcoming text stays visibly dimmer than sung text at every setting.
    func upcomingColor(opacity: Double) -> NSColor {
        let dimmed = upcomingColor
        return dimmed.withAlphaComponent(dimmed.alphaComponent * opacity)
    }
}

/// A borderless floating panel that shows Apple Music lyrics in the top-right
/// corner of the screen with a frosted-glass background.
@MainActor
final class LyricsFloatingWindow: NSPanel {
    private let currentLineLabel = NSTextField(labelWithString: "")
    private let nextLineLabel = NSTextField(labelWithString: "")
    private let trackLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let effectView = NSVisualEffectView()
    private let containerView = NSView()

    private var lyricsAppearance: LyricsAppearance
    private var lyrics: LyricsDocument = .empty
    private var track: TrackInfo?
    private var lastPosition: TimeInterval = 0
    private var isDragging = false
    private var lastDragScreenPoint: NSPoint?
    private var dragView: DragHandlingView?

    /// Called when the user finishes dragging the window to a new location.
    var onPositionChange: ((NSPoint) -> Void)?

    init(appearance: LyricsAppearance) {
        self.lyricsAppearance = appearance

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureContent()
        positionAtTopRight()
        applyAppearance()
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = !lyricsAppearance.allowsDragging
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    private func configureContent() {
        // Frosted glass background
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false

        // Content container with rounded clipping. It is a sibling of the
        // frosted-glass `effectView` (not a subview) so `backgroundOpacity`
        // dims only the glass and never the labels; text opacity is applied
        // independently through the label colors.
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true

        // Track/artist header
        trackLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        trackLabel.textColor = NSColor.secondaryLabelColor
        trackLabel.lineBreakMode = .byTruncatingTail
        trackLabel.maximumNumberOfLines = 1
        trackLabel.translatesAutoresizingMaskIntoConstraints = false

        artistLabel.font = .systemFont(ofSize: 11, weight: .regular)
        artistLabel.textColor = NSColor.tertiaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1
        artistLabel.translatesAutoresizingMaskIntoConstraints = false

        // Current lyric line (prominent)
        currentLineLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        currentLineLabel.textColor = .labelColor
        currentLineLabel.alignment = .center
        currentLineLabel.lineBreakMode = .byWordWrapping
        currentLineLabel.maximumNumberOfLines = 2
        currentLineLabel.translatesAutoresizingMaskIntoConstraints = false

        // Next lyric line (secondary)
        nextLineLabel.font = .systemFont(ofSize: 14, weight: .regular)
        nextLineLabel.textColor = NSColor.labelColor.withAlphaComponent(0.55)
        nextLineLabel.alignment = .center
        nextLineLabel.lineBreakMode = .byTruncatingTail
        nextLineLabel.maximumNumberOfLines = 1
        nextLineLabel.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [trackLabel, artistLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 1
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(contentStack)
        containerView.addSubview(currentLineLabel)
        containerView.addSubview(nextLineLabel)

        let contentView = NSView()
        // The glass is the background layer; the label container sits above it
        // as a sibling so background opacity never dims the text.
        contentView.addSubview(effectView)
        contentView.addSubview(containerView)

        // Transparent drag overlay: intercepts mouse events only when dragging
        // is enabled so the user can reposition the window freely.
        let dragView = DragHandlingView()
        dragView.isEnabled = lyricsAppearance.allowsDragging
        dragView.onMouseDown = { [weak self] in
            self?.lastDragScreenPoint = NSEvent.mouseLocation
            self?.isDragging = true
        }
        dragView.onMouseDragged = { [weak self] delta in
            guard let self else { return }
            self.setFrameOrigin(NSPoint(
                x: self.frame.origin.x + delta.x,
                y: self.frame.origin.y + delta.y
            ))
        }
        dragView.onMouseUp = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            self.lastDragScreenPoint = nil
            self.onPositionChange?(self.frame.origin)
        }
        dragView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dragView)
        self.dragView = dragView

        self.contentView = contentView

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            dragView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dragView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            currentLineLabel.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 10),
            currentLineLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            currentLineLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            nextLineLabel.topAnchor.constraint(equalTo: currentLineLabel.bottomAnchor, constant: 6),
            nextLineLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            nextLineLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            nextLineLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
        ])

        currentLineLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        currentLineLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        nextLineLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }

    // MARK: - Positioning

    private func positionAtTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let margin: CGFloat = 12
        let visibleFrame = screen.visibleFrame
        let windowWidth = frame.width
        setFrameTopLeftPoint(
            NSPoint(
                x: visibleFrame.maxX - windowWidth - margin,
                y: visibleFrame.maxY - margin
            )
        )
    }

    /// Restores a previously saved origin, falling back to the top-right
    /// default when no saved position is available.
    func restorePosition(_ point: NSPoint?) {
        guard let point else {
            positionAtTopRight()
            return
        }
        setFrameOrigin(point)
    }

    func setAllowsDragging(_ allows: Bool) {
        guard lyricsAppearance.allowsDragging != allows else { return }
        lyricsAppearance.allowsDragging = allows
        ignoresMouseEvents = !allows
        dragView?.isEnabled = allows
        if !allows {
            isDragging = false
        }
    }

    // MARK: - Mouse dragging

    // Dragging is handled by `DragHandlingView` in the content view, which
    // intercepts mouse events only when `allowsDragging` is enabled.

    // MARK: - Public API

    func update(track: TrackInfo, lyrics: LyricsDocument, position: TimeInterval) {
        self.track = track
        self.lyrics = lyrics
        self.lastPosition = position

        trackLabel.stringValue = track.title
        artistLabel.stringValue = track.artist

        if let line = lyrics.line(at: position) {
            let rendered = KaraokeRenderer.attributed(
                line: line,
                position: position,
                font: currentLineLabel.font ?? .systemFont(ofSize: lyricsAppearance.fontSize, weight: .semibold),
                sungColor: lyricsAppearance.textColor.sungColor(opacity: lyricsAppearance.textOpacity),
                upcomingColor: lyricsAppearance.textColor.upcomingColor(opacity: lyricsAppearance.textOpacity),
                karaokeEnabled: lyricsAppearance.karaokeEnabled
            )
            if let translation = line.translation, !translation.isEmpty {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.lineSpacing = 2
                let translated = NSAttributedString(
                    string: "\n" + translation,
                    attributes: [
                        .font: NSFont.systemFont(
                            ofSize: max(11, lyricsAppearance.fontSize * 0.55),
                            weight: .regular
                        ),
                        .foregroundColor: lyricsAppearance.textColor.upcomingColor(
                            opacity: lyricsAppearance.textOpacity * 0.8
                        ),
                        .paragraphStyle: paragraph
                    ]
                )
                let mutable = NSMutableAttributedString(attributedString: rendered)
                mutable.append(translated)
                currentLineLabel.attributedStringValue = mutable
            } else {
                currentLineLabel.attributedStringValue = rendered
            }
        } else {
            currentLineLabel.stringValue = "♪"
        }

        if lyricsAppearance.showsNextLine,
           let index = lyrics.lineIndex(at: position),
           index + 1 < lyrics.lines.count {
            let next = lyrics.lines[index + 1]
            nextLineLabel.stringValue = next.text
            nextLineLabel.isHidden = false
        } else {
            nextLineLabel.isHidden = true
        }

        nextLineLabel.textColor = lyricsAppearance.textColor.color
            .withAlphaComponent(lyricsAppearance.textOpacity * 0.55)
        trackLabel.textColor = lyricsAppearance.textColor.color
            .withAlphaComponent(lyricsAppearance.textOpacity * 0.55)
        artistLabel.textColor = lyricsAppearance.textColor.color
            .withAlphaComponent(lyricsAppearance.textOpacity * 0.4)
    }

    func showLyrics() {
        orderFrontRegardless()
    }

    func hideLyrics() {
        orderOut(nil)
    }

    func setAppearance(_ appearance: LyricsAppearance) {
        let draggingChanged = lyricsAppearance.allowsDragging != appearance.allowsDragging
        self.lyricsAppearance = appearance
        applyAppearance()
        if draggingChanged {
            ignoresMouseEvents = !appearance.allowsDragging
            dragView?.isEnabled = appearance.allowsDragging
            if !appearance.allowsDragging {
                isDragging = false
            }
        }
        if let track, !lyrics.lines.isEmpty {
            update(track: track, lyrics: lyrics, position: lastPosition)
        }
    }

    // MARK: - Appearance

    private func applyAppearance() {
        currentLineLabel.font = .systemFont(ofSize: lyricsAppearance.fontSize, weight: .semibold)
        nextLineLabel.font = .systemFont(ofSize: max(11, lyricsAppearance.fontSize * 0.6), weight: .regular)

        let radius = lyricsAppearance.cornerRadius
        effectView.maskImage = Self.roundedMaskImage(
            size: NSSize(width: 420, height: 140),
            cornerRadius: radius
        )
        effectView.alphaValue = lyricsAppearance.backgroundOpacity
        containerView.layer?.cornerRadius = radius
        containerView.layer?.masksToBounds = true
    }

    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: size),
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius,
            bottom: cornerRadius, right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

/// Builds an attributed string for karaoke-style word highlighting. Words that
/// have already been sung use `sungColor`; upcoming words use `upcomingColor`.
/// While a word is being sung, its characters transition progressively so the
/// current position is clearly visible.
enum KaraokeRenderer {
    static func attributed(
        line: LyricLine,
        position: TimeInterval,
        font: NSFont,
        sungColor: NSColor,
        upcomingColor: NSColor,
        karaokeEnabled: Bool = true
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2

        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        // When karaoke highlighting is disabled, the whole line uses the sung
        // color and no sung/upcoming distinction is painted. The per-line and
        // per-word timings in Apple Music's TTML are approximate, so this lets
        // users opt out of the progressive coloring when it does not line up.
        guard karaokeEnabled else {
            var attrs = base
            attrs[.foregroundColor] = sungColor
            result.append(NSAttributedString(string: line.text, attributes: attrs))
            return result
        }

        // No per-word timings: fall back to whole-line coloring. If the line
        // has an end time, paint a left-to-right gradient based on playback
        // progress so karaoke progress is still visible.
        guard !line.words.isEmpty else {
            let end = line.end
            if let end, end > line.time {
                let progress = min(1, max(0, (position - line.time) / (end - line.time)))
                if progress <= 0 {
                    var attrs = base
                    attrs[.foregroundColor] = upcomingColor
                    result.append(NSAttributedString(string: line.text, attributes: attrs))
                } else if progress >= 1 {
                    var attrs = base
                    attrs[.foregroundColor] = sungColor
                    result.append(NSAttributedString(string: line.text, attributes: attrs))
                } else {
                    appendGradient(
                        line.text,
                        progress: progress,
                        into: result,
                        base: base,
                        sungColor: sungColor,
                        upcomingColor: upcomingColor
                    )
                }
            } else {
                var attrs = base
                attrs[.foregroundColor] = position >= line.time ? sungColor : upcomingColor
                result.append(NSAttributedString(string: line.text, attributes: attrs))
            }
            return result
        }

        for word in line.words {
            appendWord(
                word,
                position: position,
                into: result,
                base: base,
                sungColor: sungColor,
                upcomingColor: upcomingColor
            )
        }
        return result
    }

    private static func appendWord(
        _ word: LyricWord,
        position: TimeInterval,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        sungColor: NSColor,
        upcomingColor: NSColor
    ) {
        let text = word.text
        guard !text.isEmpty else { return }

        if position >= word.end {
            var attrs = base
            attrs[.foregroundColor] = sungColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        if position < word.start {
            var attrs = base
            attrs[.foregroundColor] = upcomingColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        // Mid-word: paint a progressive fraction of grapheme clusters.
        let duration = max(0.04, word.end - word.start)
        let progress = min(1, max(0, (position - word.start) / duration))
        let clusters = Array(text)
        guard clusters.count > 1 else {
            var attrs = base
            attrs[.foregroundColor] = sungColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        let sungCount = min(clusters.count, max(1, Int(ceil(progress * Double(clusters.count)))))
        let sungPart = String(clusters.prefix(sungCount))
        let restPart = String(clusters.suffix(clusters.count - sungCount))

        var sungAttrs = base
        sungAttrs[.foregroundColor] = sungColor
        result.append(NSAttributedString(string: sungPart, attributes: sungAttrs))

        if !restPart.isEmpty {
            var restAttrs = base
            restAttrs[.foregroundColor] = upcomingColor
            result.append(NSAttributedString(string: restPart, attributes: restAttrs))
        }
    }

    /// Paints a whole line with a left-to-right gradient when no per-word
    /// timings are available but the line has a start and end time.
    private static func appendGradient(
        _ text: String,
        progress: Double,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        sungColor: NSColor,
        upcomingColor: NSColor
    ) {
        let clusters = Array(text)
        guard clusters.count > 1 else {
            var attrs = base
            attrs[.foregroundColor] = progress >= 0.5 ? sungColor : upcomingColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        let sungCount = min(clusters.count, max(1, Int(ceil(progress * Double(clusters.count)))))
        let sungPart = String(clusters.prefix(sungCount))
        let restPart = String(clusters.suffix(clusters.count - sungCount))

        var sungAttrs = base
        sungAttrs[.foregroundColor] = sungColor
        result.append(NSAttributedString(string: sungPart, attributes: sungAttrs))

        if !restPart.isEmpty {
            var restAttrs = base
            restAttrs[.foregroundColor] = upcomingColor
            result.append(NSAttributedString(string: restPart, attributes: restAttrs))
        }
    }
}

/// A transparent overlay that captures mouse events for window dragging.
/// It only intercepts events when `isEnabled` is true, so the lyrics window
/// remains click-through when dragging is disabled.
private final class DragHandlingView: NSView {
    var isEnabled = false
    var onMouseDown: (() -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?

    private var lastScreenPoint: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        lastScreenPoint = NSEvent.mouseLocation
        onMouseDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let last = lastScreenPoint else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - last.x, y: current.y - last.y)
        lastScreenPoint = current
        onMouseDragged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        lastScreenPoint = nil
        onMouseUp?()
    }
}
