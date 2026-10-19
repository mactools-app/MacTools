import AppKit
import Foundation

// Export the shared starter-pack symbols at a consistent size, without canvas padding.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf:
    root.appendingPathComponent("Sources/Resources/StarterPacks.json"))) as! [String: Any]
let packs = catalog["packs"] as! [[String: Any]]
let plugins = catalog["plugins"] as! [String: [String: Any]]
let symbols = Set(packs.map { $0["symbol"] as! String } + plugins.values.map { $0["symbol"] as! String })
let directory = root.appendingPathComponent("docs/assets/starter-pack-symbols")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for name in symbols.sorted() {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 40, weight: .regular)),
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot render starter-pack symbol: \(name)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = min(104 / image.size.width, 104 / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(x: (128 - size.width) / 2, y: (128 - size.height) / 2,
                         width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()

    var minX = 128, minY = 128, maxX = -1, maxY = -1
    for y in 0..<128 {
        for x in 0..<128 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY,
          let cropped = bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY,
              width: maxX - minX + 1, height: maxY - minY + 1)),
          let data = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
        fatalError("Empty starter-pack symbol: \(name)")
    }
    try data.write(to: directory.appendingPathComponent("\(name).png"))
}
print("Exported \(symbols.count) starter-pack symbols")
