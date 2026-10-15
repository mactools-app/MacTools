import AppKit
import CoreImage
import Vision
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class AnnotationRendererTests: XCTestCase {
    func testSpotlightKeepsOverlappingRegionsClearThroughDraftCommitAndUndoAtBothScales() throws {
        let selection = NSRect(x: 20, y: 10, width: 120, height: 100)
        let stroke = Stroke(color: .red, width: 4)
        let first = Item(shape: .spotlight(NSRect(x: 35, y: 25, width: 40, height: 40)), stroke: stroke)
        let second = Item(shape: .spotlight(NSRect(x: 55, y: 45, width: 40, height: 40)), stroke: stroke)

        for scale: CGFloat in [1, 2] {
            let renderer = try whiteRenderer(scale: scale)
            func render(_ items: [Item], draft: Item? = nil) throws -> NSBitmapImageRep {
                let raster = try XCTUnwrap(renderer.render(
                    selection: selection, items: items, draft: draft,
                    radius: 0, shadowSize: 0, shadowColor: .black
                ))
                return NSBitmapImageRep(cgImage: raster.image)
            }
            func brightness(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
                let color = try XCTUnwrap(bitmap.colorAt(
                    x: Int((x - selection.minX) * scale), y: Int((selection.maxY - y) * scale)
                )?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
                return color.redComponent
            }

            let draft = try render([first], draft: second)
            let committed = try render([first, second])
            XCTAssertEqual(committed.pixelsWide, Int(selection.width * scale))
            XCTAssertEqual(committed.pixelsHigh, Int(selection.height * scale))
            for bitmap in [draft, committed] {
                // Each region and their overlap remain clear, with a single dim layer outside.
                for (x, y): (CGFloat, CGFloat) in [(45, 35), (85, 75), (65, 55)] {
                    XCTAssertEqual(try brightness(bitmap, x, y), 1, accuracy: 0.01)
                }
                XCTAssertEqual(try brightness(bitmap, 125, 95), 0.5, accuracy: 0.02)
                XCTAssertLessThan(try brightness(bitmap, 36, 26), 0.8, "The highlight has rounded corners")
            }
            let undone = try render([first])
            XCTAssertEqual(try brightness(undone, 45, 35), 1, accuracy: 0.01)
            XCTAssertEqual(try brightness(undone, 85, 75), 0.5, accuracy: 0.02)
            XCTAssertEqual(try brightness(render([]), 125, 95), 1, accuracy: 0.01)
        }
    }

    func testSpotlightOutsideSelectionOrTooSmallDoesNotDimExport() throws {
        let renderer = try whiteRenderer(scale: 1)
        let selection = NSRect(x: 20, y: 10, width: 120, height: 100)
        let raster = try XCTUnwrap(renderer.render(
            selection: selection,
            items: [NSRect(x: 0, y: 0, width: 10, height: 10),
                    NSRect(x: 40, y: 40, width: 1, height: 1)].map {
                Item(shape: .spotlight($0), stroke: Stroke(color: .red, width: 2))
            },
            radius: 0, shadowSize: 0, shadowColor: .black
        ))
        let bitmap = NSBitmapImageRep(cgImage: raster.image)
        let color = try XCTUnwrap(bitmap.colorAt(x: 60, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
    }

    func testExportKeepsQRCodeRedactedUnderOtherAnnotationsAtBothDisplayScales() throws {
        let payload = "mactools-private-token"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let generated = try XCTUnwrap(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let qr = try XCTUnwrap(CIContext().createCGImage(generated, from: generated.extent))
        let padding = 24
        let width = qr.width + padding * 2
        let height = qr.height + padding * 2
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(qr, in: CGRect(x: padding, y: padding, width: qr.width, height: qr.height))
        let original = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(try decodedPayloads(original), [payload], "The source fixture must be readable")

        for scale: CGFloat in [1, 2] {
            let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
            let region = NSRect(x: CGFloat(padding) / scale, y: CGFloat(padding) / scale,
                                width: CGFloat(qr.width) / scale, height: CGFloat(qr.height) / scale)
            let stroke = Stroke(color: .red, width: 2)
            let renderer = AnnotationRenderer(image: original, scale: scale, size: size)
            // These effects sample the unredacted source, so neither may uncover the mask.
            let raster = try XCTUnwrap(renderer.render(
                selection: NSRect(origin: .zero, size: size),
                items: [.qrMask(region), Item(shape: .mosaic(region), stroke: stroke),
                        Item(shape: .spotlight(region), stroke: stroke)],
                draft: Item(shape: .mosaic(region), stroke: stroke),
                radius: 0, shadowSize: 0, shadowColor: .black
            ))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: ScreenshotImageEncoder.encodePNG(raster)))
            XCTAssertTrue(try decodedPayloads(XCTUnwrap(bitmap.cgImage)).isEmpty, "Scale: \(scale)")
            let center = try XCTUnwrap(bitmap.colorAt(x: width / 2, y: height / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(center.alphaComponent, 1)
            XCTAssertEqual(center.redComponent, 0)
            XCTAssertEqual(center.greenComponent, 0)
            XCTAssertEqual(center.blueComponent, 0)
            let outside = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(outside.redComponent, 0)
            XCTAssertLessThan(outside.redComponent, 1)
        }
    }

    func testMosaicAndFillHideTextFromRecognition() throws {
        let secret = "4829 1735 6604"
        let (source, size, textRect) = try textImage(secret, scale: 2)
        XCTAssertTrue(try recognizedText(source).contains("4829"), "The source fixture must be readable")

        for filled in [false, true] {
            let renderer = AnnotationRenderer(image: source, scale: 2, size: size)
            let shape: Shape = filled ? .rect(textRect) : .mosaic(textRect)
            let raster = try XCTUnwrap(renderer.render(
                selection: NSRect(origin: .zero, size: size),
                items: [Item(shape: shape, stroke: Stroke(color: .systemRed, width: 2, filled: filled))],
                radius: 0, shadowSize: 0, shadowColor: .black))
            let text = try recognizedText(raster.image)
            for group in secret.split(separator: " ") {
                XCTAssertFalse(text.contains(group), "filled: \(filled), recognized: \(text)")
            }
        }
    }

    func testMaskEdgesOnHalfPixelsDoNotBlendWithTheSource() throws {
        let source = try checkerboard(width: 200, height: 120)
        let size = NSSize(width: 100, height: 60)
        // The left edge falls on device pixel 20.5; an unaligned cover would blend column 20.
        let region = NSRect(x: 10.25, y: 10.25, width: 60, height: 40)
        for filled in [false, true] {
            let renderer = AnnotationRenderer(image: source, scale: 2, size: size)
            let shape: Shape = filled ? .rect(region) : .mosaic(region)
            let raster = try XCTUnwrap(renderer.render(
                selection: NSRect(origin: .zero, size: size),
                items: [Item(shape: shape, stroke: Stroke(color: .systemRed, width: 2, filled: filled))],
                radius: 0, shadowSize: 0, shadowColor: .black))
            let bitmap = NSBitmapImageRep(cgImage: raster.image)
            for row in [30, 60, 90] {
                XCTAssertEqual(bitmap.colorAt(x: 20, y: row), bitmap.colorAt(x: 21, y: row),
                               "filled: \(filled), row: \(row)")
                XCTAssertEqual(bitmap.colorAt(x: 20, y: row)?.alphaComponent, 1)
            }
        }
    }

    func testMosaicIsOpaqueStableWithinACaptureAndVariesBetweenCaptures() throws {
        let source = try checkerboard(width: 120, height: 120, transparentLeftHalf: true)
        let size = NSSize(width: 120, height: 120)
        let selection = NSRect(origin: .zero, size: size)
        let items = [Item(shape: .mosaic(selection), stroke: Stroke(color: .red, width: 2))]
        func export(_ renderer: AnnotationRenderer) throws -> Data {
            let raster = try XCTUnwrap(renderer.render(selection: selection, items: items,
                                                       radius: 0, shadowSize: 0, shadowColor: .black))
            return try ScreenshotImageEncoder.encodePNG(raster)
        }
        let renderer = AnnotationRenderer(image: source, scale: 1, size: size)
        let png = try export(renderer)
        XCTAssertEqual(try export(renderer), png, "Preview and export must match within one capture")
        XCTAssertNotEqual(try export(AnnotationRenderer(image: source, scale: 1, size: size)), png,
                          "A fixed block pattern could be matched against rendered candidates")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        for (x, y) in [(0, 0), (60, 60), (119, 119)] {
            XCTAssertEqual(bitmap.colorAt(x: x, y: y)?.alphaComponent, 1)
        }
    }

    private func textImage(_ text: String, scale: CGFloat) throws -> (CGImage, NSSize, NSRect) {
        let size = NSSize(width: 360, height: 90)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .regular),
            .foregroundColor: NSColor.black,
        ])
        let origin = NSPoint(x: 20, y: 30)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        let textRect = NSRect(origin: origin, size: string.size()).insetBy(dx: -4, dy: -4)
        return (try XCTUnwrap(rep.cgImage), size, textRect)
    }

    private func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func checkerboard(width: Int, height: Int, transparentLeftHalf: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha: UInt8 = transparentLeftHalf && x < width / 2 ? 0 : 255
                let value: UInt8 = (x + y) % 2 == 0 ? alpha : 0
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = alpha
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func whiteRenderer(scale: CGFloat) throws -> AnnotationRenderer {
        let size = NSSize(width: 160, height: 120)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return AnnotationRenderer(image: try XCTUnwrap(context.makeImage()), scale: scale, size: size)
    }

    private func decodedPayloads(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}
