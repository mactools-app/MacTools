import AppKit

enum Shape {
    case rect(NSRect)
    case ellipse(NSRect)
    case line(from: NSPoint, to: NSPoint)
    case arrow(from: NSPoint, to: NSPoint)
    case pen([NSPoint])
    case text(String, at: NSPoint)
    case tag(Int, at: NSPoint)
    case redaction(NSRect)
    case mosaic(NSRect)
    case spotlight(NSRect)
}

struct Stroke {
    var color: NSColor
    var width: CGFloat
    var filled = false

    /// Stroke presets also select text sizes, matching the annotation toolbar.
    var fontSize: CGFloat {
        switch width {
        case 2: return 14
        case 4: return 18
        default: return 24
        }
    }
}

struct Item {
    let shape: Shape
    let stroke: Stroke

    var editableRect: NSRect? {
        switch shape {
        case .rect(let rect), .ellipse(let rect), .spotlight(let rect): return rect
        default: return nil
        }
    }

    func replacingEditableRect(_ rect: NSRect) -> Item? {
        switch shape {
        case .rect: return Item(shape: .rect(rect), stroke: stroke)
        case .ellipse: return Item(shape: .ellipse(rect), stroke: stroke)
        case .spotlight: return Item(shape: .spotlight(rect), stroke: stroke)
        default: return nil
        }
    }

    static func qrMask(_ rect: NSRect) -> Item {
        Item(shape: .redaction(rect.insetBy(dx: -6, dy: -6)), stroke: Stroke(color: .black, width: 0))
    }

    var supportsFill: Bool {
        switch shape {
        case .rect, .ellipse: return true
        default: return false
        }
    }

    /// Opaque covers draw after source-sampling effects so nothing beneath them can show through.
    var isMask: Bool {
        if case .redaction = shape { return true }
        return supportsFill && stroke.filled
    }

    /// Ellipses hit-test their outline path; other editable shapes use their bounds.
    func contains(_ point: NSPoint) -> Bool {
        if case .ellipse(let rect) = shape { return NSBezierPath(ovalIn: rect).contains(point) }
        return editableRect?.contains(point) == true
    }
}

/// Draw annotations and export the frozen image without depending on overlay interaction state.
@MainActor
final class AnnotationRenderer {
    private let cgImage: CGImage
    private let scale: CGFloat
    private let bounds: NSRect
    private let frozen: NSImage
    private var mosaicCache: [String: CGImage] = [:]
    /// One random seed per capture keeps preview and export identical while varying between captures.
    private let mosaicSeed = UInt64.random(in: .min ... .max)
    private static let mosaicBlock: CGFloat = 14

    init(image: CGImage, scale: CGFloat, size: NSSize) {
        cgImage = image
        self.scale = scale
        bounds = NSRect(origin: .zero, size: size)
        frozen = NSImage(cgImage: image, size: size)
    }

    func clearCache() { mosaicCache.removeAll() }

    static func shadowMargin(for shadowSize: CGFloat) -> CGFloat {
        shadowSize > 0 ? (shadowSize * 2 + shadowOffset(for: shadowSize)).rounded(.up) : 0
    }

    private static func shadowOffset(for shadowSize: CGFloat) -> CGFloat {
        (shadowSize / 3).rounded()
    }

    /// NSShadow blur and offset use device pixels; offscreen Retina output supplies its scale.
    func drawShadow(for rect: NSRect, radius: CGFloat, shadowSize: CGFloat,
                    shadowColor: NSColor, deviceScale: CGFloat) {
        guard shadowSize > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shadow = NSShadow()
        shadow.shadowBlurRadius = shadowSize * deviceScale
        shadow.shadowOffset = NSSize(width: 0, height: -Self.shadowOffset(for: shadowSize) * deviceScale)
        shadow.shadowColor = shadowColor.withAlphaComponent(0.5)
        shadow.set()
        shadowColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    func drawItems(_ items: [Item], draft: Item? = nil, selection: NSRect) {
        for item in items where !item.isMask {
            draw(item, cache: true, selection: selection)
        }
        // Draft geometry changes every frame, so it must not grow the mosaic cache.
        if let draft, !draft.isMask { draw(draft, cache: false, selection: selection) }
        drawSpotlights(items + (draft.map { [$0] } ?? []), selection: selection)
        // Mosaic samples the frozen source; keep masks above it.
        for item in items where item.isMask {
            draw(item, cache: true, selection: selection)
        }
        if let draft, draft.isMask { draw(draft, cache: false, selection: selection) }
    }

    private func draw(_ item: Item, cache: Bool, selection: NSRect) {
        item.stroke.color.set()
        let width = item.stroke.width
        switch item.shape {
        case .rect(let r):
            drawClosedShape(NSBezierPath(rect: item.stroke.filled ? deviceAligned(r) : r),
                            style: item.stroke, selection: selection)
        case .ellipse(let r):
            drawClosedShape(NSBezierPath(ovalIn: r), style: item.stroke, selection: selection)
        case .line(let from, let to):
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            stroke(path, width: width)
        case .arrow(let from, let to):
            let line = NSBezierPath()
            line.move(to: from)
            line.line(to: to)
            stroke(line, width: width)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let len = 8 + width * 2, spread: CGFloat = .pi / 7
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: NSPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread)))
            head.line(to: NSPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread)))
            head.close()
            head.fill()
        case .pen(let points):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            stroke(path, width: width)
        case .text(let string, let origin):
            NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: item.stroke.fontSize), .foregroundColor: item.stroke.color,
            ]).draw(at: origin)
        case .tag(let number, let at):
            let r = NSRect(x: at.x - 11, y: at.y - 11, width: 22, height: 22)
            NSBezierPath(ovalIn: r).fill()
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: item.stroke.color == .white ? NSColor.black : NSColor.white,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        case .redaction(let r):
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setBlendMode(.copy)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(deviceAligned(r).intersection(selection).intersection(bounds))
            context.restoreGState()
        case .mosaic(let r):
            drawMosaic(in: r, cache: cache, selection: selection)
        case .spotlight:
            break // All spotlight regions share one dimming layer.
        }
    }

    /// Expands a cover to whole device pixels. A half-pixel edge would blend the source beneath it.
    private func deviceAligned(_ rect: NSRect) -> NSRect {
        guard let cg = NSGraphicsContext.current?.cgContext else { return rect }
        return cg.convertToUserSpace(cg.convertToDeviceSpace(rect).integral)
    }

    private func drawClosedShape(_ path: NSBezierPath, style: Stroke, selection: NSRect) {
        guard style.filled else { stroke(path, width: style.width); return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: selection.intersection(bounds)).addClip()
        style.color.withAlphaComponent(1).setFill()
        path.fill()
    }

    private func drawSpotlights(_ items: [Item], selection: NSRect) {
        let regions = items.compactMap { item -> NSRect? in
            guard case .spotlight(let rect) = item.shape else { return nil }
            let clipped = rect.intersection(selection).intersection(bounds)
            return clipped.width >= 2 && clipped.height >= 2 ? clipped : nil
        }
        guard !regions.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Intersect the outside of each region so overlapping highlights stay clear.
        for rect in regions {
            let mask = NSBezierPath(rect: selection.intersection(bounds))
            let radius = min(8, min(rect.width, rect.height) / 2)
            mask.append(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius))
            mask.windingRule = .evenOdd
            mask.addClip()
        }
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: selection.intersection(bounds)).fill()
    }

    private func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.stroke()
    }

    /// Pixelation keeps only a quantized, seeded-jitter average per block. Exact block averages
    /// can be matched against rendered candidates (as Depix does), so blocks stay coarse and noisy.
    private func drawMosaic(in rect: NSRect, cache: Bool, selection: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext,
              let (sub, r) = crop(deviceAligned(rect), selection: selection) else { return }
        let key = "\(r)"
        let image: CGImage
        if let hit = mosaicCache[key] {
            image = hit
        } else {
            guard let made = mosaicImage(from: sub, size: r.size) else { return }
            if cache { mosaicCache[key] = made }
            image = made
        }
        cg.saveGState()
        cg.interpolationQuality = .none
        cg.draw(image, in: r)
        cg.restoreGState()
    }

    private func mosaicImage(from source: CGImage, size: NSSize) -> CGImage? {
        let cols = max(1, Int((size.width / Self.mosaicBlock).rounded()))
        let rows = max(1, Int((size.height / Self.mosaicBlock).rounded()))
        // Downsample to k×k samples per block, then average them: close to an area average
        // without visiting every source pixel of a large region.
        let k = 4, w = cols * k, h = rows * k
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var samples = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = samples.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Alpha stays 255: a mosaic must never let the source show through.
        var blocks = [UInt8](repeating: 255, count: cols * rows * 4)
        for by in 0..<rows {
            for bx in 0..<cols {
                var sum = (0, 0, 0)
                for y in by * k..<(by + 1) * k {
                    for x in bx * k..<(bx + 1) * k {
                        let i = (y * w + x) * 4
                        sum.0 += Int(samples[i]); sum.1 += Int(samples[i + 1]); sum.2 += Int(samples[i + 2])
                    }
                }
                let jitter = mosaicNoise(bx, by)
                let o = (by * cols + bx) * 4
                for (c, total) in [sum.0, sum.1, sum.2].enumerated() {
                    let value = total / (k * k) + jitter
                    blocks[o + c] = UInt8(clamping: value / 8 * 8 + 4)
                }
            }
        }
        return blocks.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: cols, height: rows, bitsPerComponent: 8,
                      bytesPerRow: cols * 4, space: space, bitmapInfo: info)?.makeImage()
        }
    }

    /// Deterministic ±12 luminance jitter from the capture seed and block position (SplitMix64).
    private func mosaicNoise(_ x: Int, _ y: Int) -> Int {
        var z = mosaicSeed &+ UInt64(truncatingIfNeeded: x) &* 0x9E37_79B9_7F4A_7C15
            &+ UInt64(truncatingIfNeeded: y) &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % 25) - 12
    }

    /// Convert bottom-left view points to top-left frozen-image pixels.
    func crop(_ rect: NSRect, selection: NSRect) -> (CGImage, NSRect)? {
        let r = rect.intersection(selection).intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let px = Geometry.cropRect(viewRect: r, scale: scale, imagePixelHeight: CGFloat(cgImage.height))
        guard let sub = cgImage.cropping(to: px) else { return nil }
        return (sub, r)
    }

    /// Preview and export share drawing; only the destination context and scale differ.
    func render(selection: NSRect, items: [Item], draft: Item? = nil, radius: CGFloat,
                shadowSize: CGFloat, shadowColor: NSColor) -> ScreenshotRaster? {
        guard !selection.isEmpty else { return nil }

        // A plain screenshot needs no compositing. Encode the source crop directly so
        // translucent windows retain their captured pixels and embedded color space.
        if items.isEmpty, draft == nil, radius == 0, shadowSize == 0,
           selection.intersection(bounds) == selection,
           let (cropped, _) = crop(selection, selection: selection) {
            return ScreenshotRaster(image: cropped, logicalSize: selection.size)
        }

        let m = Self.shadowMargin(for: shadowSize)
        let size = NSSize(width: selection.width + m * 2, height: selection.height + m * 2)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        let sourceColorSpace = cgImage.colorSpace
        let colorSpace = sourceColorSpace?.model == .rgb
            ? sourceColorSpace
            : CGColorSpace(name: CGColorSpace.sRGB)
        guard w > 0, h > 0, let colorSpace,
              let bitmapContext = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        bitmapContext.scaleBy(x: scale, y: scale)
        bitmapContext.translateBy(x: m - selection.minX, y: m - selection.minY)
        drawShadow(for: selection, radius: radius, shadowSize: shadowSize, shadowColor: shadowColor, deviceScale: scale)
        NSBezierPath(roundedRect: selection, xRadius: radius, yRadius: radius).setClip()
        frozen.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        drawItems(items, draft: draft, selection: selection)
        NSGraphicsContext.restoreGraphicsState()

        guard let rendered = bitmapContext.makeImage() else { return nil }
        return ScreenshotRaster(image: rendered, logicalSize: size)
    }
}
