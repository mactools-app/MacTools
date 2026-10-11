import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MenuBarIconAppearance: String, CaseIterable, Identifiable, Codable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return AppL10n.settings("menuBarIcon.appearance.light", defaultValue: "浅色模式")
        case .dark:
            return AppL10n.settings("menuBarIcon.appearance.dark", defaultValue: "深色模式")
        }
    }
}

struct MenuBarIconLocalSelection: Codable, Equatable {
    let fileName: String
    let frameFileNames: [String]
    let frameDuration: TimeInterval

    init(
        fileName: String,
        frameFileNames: [String],
        frameDuration: TimeInterval
    ) {
        self.fileName = fileName
        self.frameFileNames = frameFileNames
        self.frameDuration = frameDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decode(String.self, forKey: .fileName)
        frameFileNames = try container.decodeIfPresent([String].self, forKey: .frameFileNames) ?? [fileName]
        frameDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .frameDuration) ?? 1.0 / 6.0
    }
}

struct MenuBarIconImagePayload: Equatable {
    let image: NSImage
    let isTemplate: Bool
    let animationFrames: [NSImage]
    let frameDuration: TimeInterval

    var isAnimated: Bool {
        animationFrames.count > 1
    }
}

enum MenuBarIconProcessing {
    static let maxAnimationFileSize = 5 * 1024 * 1024
    static let maxAnimationFrames = 24
    static let maxAnimationSourceFrames = 120
    static let animationFramesPerSecond: TimeInterval = 6
    static let maxSourcePixelArea = 1_600 * 1_600
    static let standardIconPointSize: CGFloat = 18
    private static let standardIconContentPointSize: CGFloat = 16

    static let supportedImageContentTypes: [UTType] = [
        .png,
        .jpeg,
        .webP,
        .icns,
        .image
    ].compactMap { $0 }

    static let supportedAnimationContentTypes: [UTType] = [
        .gif,
        .mpeg4Movie,
        .quickTimeMovie,
        .movie
    ].compactMap { $0 }

    static func renderedImage(from image: NSImage) -> NSImage? {
        prepareFrames(from: [image]).images.first
    }

    static func renderedImages(from images: [NSImage]) -> [NSImage] {
        prepareFrames(from: images).images
    }

    struct PreparedFrames {
        let images: [NSImage]
        let supportsTemplateRendering: Bool
    }

    struct PreparedCGFrames: Sendable {
        let images: [CGImage]
        let supportsTemplateRendering: Bool

        func makeImages() -> PreparedFrames {
            PreparedFrames(
                images: images.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: standardIconPointSize)) },
                supportsTemplateRendering: supportsTemplateRendering
            )
        }
    }

    static func prepareFrames(from images: [NSImage]) -> PreparedFrames {
        let sources = images.compactMap { image -> CGImage? in
            cgImage(from: image)
        }
        let prepared = prepareCGFrames(from: sources)
        return PreparedFrames(
            images: prepared.images.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: standardIconPointSize)) },
            supportsTemplateRendering: sources.count == images.count && prepared.supportsTemplateRendering
        )
    }

    static func prepareFrames(at urls: [URL]) -> PreparedCGFrames {
        let sources = urls.compactMap { url -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return prepareCGFrames(from: sources)
    }

    private static func prepareCGFrames(from sources: [CGImage]) -> PreparedCGFrames {
        let analyses = sources.map { analyzeAlpha(in: $0) }
        let sharedVisibleBounds = analyses
            .compactMap { $0?.visibleBounds }
            .reduce(CGRect?.none) { partialBounds, bounds in
                partialBounds?.union(bounds) ?? bounds
            }

        let frames = sources.compactMap { source in
            renderedCGImage(from: source, visibleBounds: sharedVisibleBounds)
        }
        // Inspect source pixels before normalization adds its own transparent padding.
        // Blank animation frames are valid, but at least one frame must be visible.
        let supportsTemplateRendering = !frames.isEmpty
            && frames.count == sources.count
            && analyses.allSatisfy { $0?.hasTransparency == true }
            && analyses.contains { $0?.visibleBounds != nil }
        return PreparedCGFrames(images: frames, supportsTemplateRendering: supportsTemplateRendering)
    }

    private static func renderedCGImage(from source: CGImage, visibleBounds: CGRect?) -> CGImage? {

        let pointSize = standardIconPointSize
        let scaleFactor: CGFloat = 2
        let canvasHeightPixels = Int((pointSize * scaleFactor).rounded())
        let contentHeightPixels = Int((standardIconContentPointSize * scaleFactor).rounded())
        let paddingPixels = max(0, (canvasHeightPixels - contentHeightPixels) / 2)
        guard canvasHeightPixels > 0, contentHeightPixels > 0 else {
            return nil
        }

        // Normalize artwork bounds before fitting so transparent source padding does not change its visual size.
        let visibleSource: CGImage
        let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let cropBounds = visibleBounds?.intersection(sourceBounds)
        if let cropBounds, let cropped = source.cropping(to: cropBounds) {
            visibleSource = cropped
        } else {
            visibleSource = source
        }
        let sourceWidth = CGFloat(visibleSource.width)
        let sourceHeight = CGFloat(visibleSource.height)
        let renderScale = CGFloat(contentHeightPixels) / sourceHeight
        let drawWidth = sourceWidth * renderScale
        let drawHeight = sourceHeight * renderScale
        let canvasWidthPixels = max(
            contentHeightPixels + (paddingPixels * 2),
            Int(ceil(drawWidth)) + (paddingPixels * 2)
        )
        let canvasSize = CGSize(width: canvasWidthPixels, height: canvasHeightPixels)
        guard let context = CGContext(
            data: nil,
            width: canvasWidthPixels,
            height: canvasHeightPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: canvasSize))
        context.interpolationQuality = .high

        let originX = (canvasSize.width - drawWidth) / 2
        let originY = (canvasSize.height - drawHeight) / 2
        let drawSize = CGSize(width: drawWidth, height: drawHeight)
        let origin = CGPoint(
            x: originX,
            y: originY
        )

        context.draw(visibleSource, in: CGRect(origin: origin, size: drawSize))

        return context.makeImage()
    }

    private struct AlphaAnalysis {
        let visibleBounds: CGRect?
        let hasTransparency: Bool
    }

    private static func analyzeAlpha(in image: CGImage) -> AlphaAnalysis? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var hasVisiblePixel = false
        var hasTransparency = false

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[((y * width) + x) * 4 + 3]
                hasTransparency = hasTransparency || alpha < 255
                guard alpha > 8 else {
                    continue
                }

                hasVisiblePixel = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }

        let visibleBounds = hasVisiblePixel ? CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ) : nil
        return AlphaAnalysis(
            visibleBounds: visibleBounds,
            hasTransparency: hasTransparency
        )
    }

    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    @MainActor
    static func animationFrameImages(from url: URL) async throws -> [NSImage] {
        guard isFileSizeAcceptable(url) else {
            throw MenuBarIconImportError.animationTooLarge
        }

        let contentType = contentType(for: url)
        if contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .audiovisualContent) == true {
            return try await videoFrameImages(from: url)
        }

        if contentType?.conforms(to: .gif) == true || url.pathExtension.lowercased() == "gif" {
            return try imageSourceFrameImages(from: url)
        }

        throw MenuBarIconImportError.unsupportedAnimation
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func isFileSizeAcceptable(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize
        else {
            return true
        }

        return fileSize <= maxAnimationFileSize
    }

    private static func contentType(for url: URL) -> UTType? {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]) else {
            return nil
        }

        return values.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    private static func imageSourceFrameImages(from url: URL) throws -> [NSImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MenuBarIconImportError.cannotDecodeAnimation
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            throw MenuBarIconImportError.notAnimated
        }
        guard frameCount <= maxAnimationSourceFrames else {
            throw MenuBarIconImportError.animationTooComplex
        }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width * height > maxSourcePixelArea {
            throw MenuBarIconImportError.animationTooLarge
        }

        let targetCount = min(frameCount, maxAnimationFrames)
        let frameStep = max(1, Int(ceil(Double(frameCount) / Double(targetCount))))
        var frames: [NSImage] = []

        for index in stride(from: 0, to: frameCount, by: frameStep) where frames.count < maxAnimationFrames {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }

            frames.append(NSImage(cgImage: frame, size: .zero))
        }

        guard frames.count > 1 else {
            throw MenuBarIconImportError.cannotDecodeAnimation
        }

        return frames
    }

    private static func imageSourceFrameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 1.0 / animationFramesPerSecond
        }

        let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
        let delay = unclampedDelay ?? gifProperties[kCGImagePropertyGIFDelayTime] as? TimeInterval
        return max(delay ?? (1.0 / animationFramesPerSecond), 0.02)
    }

    @MainActor
    private static func videoFrameImages(from url: URL) async throws -> [NSImage] {
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        guard duration.isFinite, duration > 0 else {
            throw MenuBarIconImportError.cannotDecodeAnimation
        }

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            let pixelArea = abs(transformedSize.width * transformedSize.height)
            guard pixelArea <= CGFloat(maxSourcePixelArea) else {
                throw MenuBarIconImportError.animationTooLarge
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)

        let frameCount = min(
            maxAnimationFrames,
            max(2, Int(ceil(duration * animationFramesPerSecond)))
        )
        var frames: [NSImage] = []

        for index in 0..<frameCount {
            let progress = frameCount == 1 ? 0 : Double(index) / Double(frameCount)
            let seconds = min(duration, progress * duration)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }

            frames.append(NSImage(cgImage: frame, size: .zero))
        }

        guard frames.count > 1 else {
            throw MenuBarIconImportError.cannotDecodeAnimation
        }

        return frames
    }
}

enum MenuBarIconImportError: Error {
    case animationTooLarge
    case animationTooComplex
    case cannotDecodeAnimation
    case notAnimated
    case unsupportedAnimation
    case requiresTransparency

    var userMessage: String {
        switch self {
        case .animationTooLarge:
            return AppL10n.settings("menuBarIcon.importError.animationTooLarge", defaultValue: "动画文件过大或分辨率过高，请选择 5 MB 以内、画面更简单的文件。")
        case .animationTooComplex:
            return AppL10n.settings("menuBarIcon.importError.animationTooComplex", defaultValue: "动画帧数过多，请选择更简单的短动画。")
        case .cannotDecodeAnimation:
            return AppL10n.settings("menuBarIcon.importError.cannotDecodeAnimation", defaultValue: "无法解析这个动画文件。")
        case .notAnimated:
            return AppL10n.settings("menuBarIcon.importError.notAnimated", defaultValue: "所选文件不是可循环播放的动画。")
        case .unsupportedAnimation:
            return AppL10n.settings("menuBarIcon.importError.unsupportedAnimation", defaultValue: "暂不支持这个动画格式，请选择 GIF 或 MP4。")
        case .requiresTransparency:
            return AppL10n.settings("menuBarIcon.importError.requiresTransparency", defaultValue: "请选择透明背景且包含可见图案的图标或动画。")
        }
    }
}

@MainActor
final class MenuBarIconSettings: ObservableObject {
    private enum DefaultsKey {
        static let storage = "menubar.icon.settings"
    }

    private struct StoredState: Codable, Equatable {
        var localIconSelection: MenuBarIconLocalSelection?
        var remoteAssetSelection: MenuBarIconRemoteAssetSelection?

        private enum CodingKeys: String, CodingKey {
            case localIconSelection
            case remoteAssetSelection
            case lightIconFileName
            case darkIconFileName
            case recentItems
        }

        init(
            localIconSelection: MenuBarIconLocalSelection? = nil,
            remoteAssetSelection: MenuBarIconRemoteAssetSelection? = nil
        ) {
            self.localIconSelection = localIconSelection
            self.remoteAssetSelection = remoteAssetSelection
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            remoteAssetSelection = try container.decodeIfPresent(
                MenuBarIconRemoteAssetSelection.self,
                forKey: .remoteAssetSelection
            )
            localIconSelection = try container.decodeIfPresent(
                MenuBarIconLocalSelection.self,
                forKey: .localIconSelection
            )

            guard localIconSelection == nil, remoteAssetSelection == nil else {
                return
            }

            let lightIconFileName = try container.decodeIfPresent(String.self, forKey: .lightIconFileName)
            let darkIconFileName = try container.decodeIfPresent(String.self, forKey: .darkIconFileName)
            let selectedFileNames = [lightIconFileName, darkIconFileName].compactMap { $0 }
            let legacySelections = try container.decodeIfPresent(
                [MenuBarIconLocalSelection].self,
                forKey: .recentItems
            ) ?? []
            localIconSelection = legacySelections.first { selectedFileNames.contains($0.fileName) }
            if localIconSelection == nil, let fileName = lightIconFileName ?? darkIconFileName {
                localIconSelection = MenuBarIconLocalSelection(
                    fileName: fileName,
                    frameFileNames: [fileName],
                    frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(localIconSelection, forKey: .localIconSelection)
            try container.encodeIfPresent(remoteAssetSelection, forKey: .remoteAssetSelection)
        }
    }

    private struct RenderedFramesCacheKey: Hashable {
        let fileName: String
        let frameFileNames: [String]
    }

    private struct RemoteFramesCacheKey: Hashable {
        let id: String
        let version: String
        let frameFileNames: [String]
    }

    private static let defaultIconName = NSImage.Name("MenuBarIcon")

    @Published private var storedState: StoredState
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var settingsRevision: Int = 0

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let remoteAssetStore: MenuBarIconRemoteAssetStore
    private let encoder = JSONEncoder()
    private var imagePayloadCache: [MenuBarIconAppearance: MenuBarIconImagePayload] = [:]
    private var renderedFramesCache: [RenderedFramesCacheKey: MenuBarIconProcessing.PreparedFrames] = [:]
    private var remoteFramesCache: [RemoteFramesCacheKey: [NSImage]] = [:]
    private var framePreparationTask: Task<Void, Never>?
    private var framePreparationRevision: UInt64 = 0
    #if DEBUG
    private var submittedFramePreparations: [Task<Void, Never>] = []
    func waitForFramePreparationForTests() async {
        for task in submittedFramePreparations { await task.value }
        submittedFramePreparations.removeAll()
    }
    #endif

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        remoteAssetStore: MenuBarIconRemoteAssetStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.remoteAssetStore = remoteAssetStore ?? MenuBarIconRemoteAssetStore(
            rootDirectory: self.rootDirectory
                .appendingPathComponent("MenuBarIcons", isDirectory: true)
                .appendingPathComponent("RemoteAssets", isDirectory: true),
            fileManager: fileManager
        )
        self.storedState = Self.loadState(userDefaults: userDefaults)
        pruneMissingLocalIconSelection()
        pruneMissingRemoteAssetSelection()
        pruneUnusedLocalIconFiles()
    }

    var hasCustomIcon: Bool {
        storedState.localIconSelection != nil || storedState.remoteAssetSelection != nil
    }

    var selectedRemoteAsset: MenuBarIconRemoteAssetSelection? {
        storedState.remoteAssetSelection
    }

    func importIcon(from sourceURL: URL, for _: MenuBarIconAppearance) {
        importIcon(from: sourceURL)
    }

    func importIcon(from sourceURL: URL) {
        clearError()

        guard let sourceImage = NSImage(contentsOf: sourceURL) else {
            lastErrorMessage = AppL10n.settings("menuBarIcon.error.readSelectedImage", defaultValue: "无法读取所选图片。")
            return
        }

        let preparedFrames = MenuBarIconProcessing.prepareFrames(from: [sourceImage])
        guard preparedFrames.supportsTemplateRendering else {
            lastErrorMessage = MenuBarIconImportError.requiresTransparency.userMessage
            return
        }

        let fileName = "icon-\(UUID().uuidString).png"
        let destinationURL = localIconsDirectory.appendingPathComponent(fileName)

        guard saveOriginalImage(sourceImage, to: destinationURL) else {
            lastErrorMessage = AppL10n.settings("menuBarIcon.error.saveSelectedImage", defaultValue: "无法保存所选图片。")
            return
        }

        let selection = MenuBarIconLocalSelection(
            fileName: fileName,
            frameFileNames: [fileName],
            frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
        )
        useLocalSelection(selection, preparedFrames: preparedFrames)
    }

    func importAnimation(from sourceURL: URL, for _: MenuBarIconAppearance) async {
        await importAnimation(from: sourceURL)
    }

    func importAnimation(from sourceURL: URL) async {
        clearError()

        let sourceFrames: [NSImage]
        do {
            sourceFrames = try await MenuBarIconProcessing.animationFrameImages(from: sourceURL)
        } catch let error as MenuBarIconImportError {
            lastErrorMessage = error.userMessage
            return
        } catch {
            lastErrorMessage = AppL10n.settings("menuBarIcon.importError.cannotDecodeAnimation", defaultValue: "无法解析这个动画文件。")
            return
        }

        let preparedFrames = MenuBarIconProcessing.prepareFrames(from: sourceFrames)
        guard preparedFrames.supportsTemplateRendering else {
            lastErrorMessage = MenuBarIconImportError.requiresTransparency.userMessage
            return
        }

        let animationID = UUID().uuidString
        let fileNames = sourceFrames.indices.map { index in
            "animation-\(animationID)-frame-\(index).png"
        }

        guard saveAnimationFrames(sourceFrames, fileNames: fileNames) else {
            lastErrorMessage = AppL10n.settings("menuBarIcon.error.saveAnimationIcon", defaultValue: "无法保存动画图标。")
            return
        }

        let selection = MenuBarIconLocalSelection(
            fileName: fileNames[0],
            frameFileNames: fileNames,
            frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
        )
        useLocalSelection(selection, preparedFrames: preparedFrames)
    }

    private func useLocalSelection(
        _ selection: MenuBarIconLocalSelection,
        preparedFrames: MenuBarIconProcessing.PreparedFrames
    ) {
        storedState.localIconSelection = selection
        clearRemoteAssetSelection()
        pruneUnusedLocalIconFiles()
        invalidateAllIconCaches()
        let cacheKey = RenderedFramesCacheKey(
            fileName: selection.fileName,
            frameFileNames: selection.frameFileNames
        )
        renderedFramesCache[cacheKey] = preparedFrames
        persist()
    }

    func useRemoteAsset(_ selection: MenuBarIconRemoteAssetSelection) {
        clearError()

        guard remoteAssetStore.hasFrames(for: selection) else {
            lastErrorMessage = AppL10n.settings("menuBarIcon.error.remoteAssetNotReady", defaultValue: "在线图标文件尚未下载完成。")
            return
        }

        storedState.remoteAssetSelection = selection
        storedState.localIconSelection = nil
        pruneUnusedLocalIconFiles()
        invalidateAllIconCaches()
        remoteAssetStore.pruneRemoteAssets(keeping: selection)
        persist()
    }

    func resetToDefault() {
        storedState.localIconSelection = nil
        storedState.remoteAssetSelection = nil
        pruneUnusedLocalIconFiles()
        remoteAssetStore.pruneRemoteAssets(keeping: nil)
        invalidateAllIconCaches()
        persist()
    }

    func imagePayload(for appearance: NSAppearance? = nil) -> MenuBarIconImagePayload {
        let resolvedAppearance = resolvedAppearance(from: appearance)
        return imagePayload(for: resolvedAppearance)
    }

    func previewImage(for appearance: MenuBarIconAppearance) -> NSImage {
        imagePayload(for: appearance).image
    }

    private func clearError() {
        lastErrorMessage = nil
    }

    private func imagePayload(for resolvedAppearance: MenuBarIconAppearance) -> MenuBarIconImagePayload {
        if let cachedPayload = imagePayloadCache[resolvedAppearance] {
            return cachedPayload
        }

        let payload = makeImagePayload(for: resolvedAppearance)
        imagePayloadCache[resolvedAppearance] = payload
        return payload
    }

    private func makeImagePayload(for _: MenuBarIconAppearance) -> MenuBarIconImagePayload {
        if let selection = storedState.localIconSelection {
            let preparedFrames = renderedFrames(for: selection)
            // Preserve existing opaque artwork instead of turning it into a solid block.
            if let payload = customImagePayload(
                frames: preparedFrames.images,
                frameDuration: selection.frameDuration,
                renderingMode: preparedFrames.supportsTemplateRendering ? .template : .original
            ) {
                return payload
            }
        }

        if let selection = storedState.remoteAssetSelection,
           remoteAssetStore.hasFrames(for: selection),
           let payload = customImagePayload(
               frames: renderedImages(for: selection),
               frameDuration: selection.frameDuration,
               renderingMode: selection.renderingMode
           ) {
            return payload
        }

        let image = Self.defaultImage()
        image.isTemplate = true
        return MenuBarIconImagePayload(
            image: image,
            isTemplate: true,
            animationFrames: [image],
            frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
        )
    }

    private func customImagePayload(
        frames: [NSImage],
        frameDuration: TimeInterval,
        renderingMode: MenuBarIconRenderingMode
    ) -> MenuBarIconImagePayload? {
        guard let image = frames.first else {
            return nil
        }

        image.isTemplate = renderingMode.isTemplate
        for frame in frames {
            frame.isTemplate = renderingMode.isTemplate
        }

        return MenuBarIconImagePayload(
            image: image,
            isTemplate: renderingMode.isTemplate,
            animationFrames: frames,
            frameDuration: frameDuration
        )
    }

    private var iconsDirectory: URL {
        rootDirectory.appendingPathComponent("MenuBarIcons", isDirectory: true)
    }

    private var localIconsDirectory: URL {
        iconsDirectory.appendingPathComponent("Recents", isDirectory: true)
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        AppStorageScope.applicationSupportRoot(fileManager: fileManager)
    }

    private static func loadState(userDefaults: UserDefaults) -> StoredState {
        guard let data = userDefaults.data(forKey: DefaultsKey.storage) else {
            return StoredState()
        }

        do {
            return try JSONDecoder().decode(StoredState.self, from: data)
        } catch {
            userDefaults.removeObject(forKey: DefaultsKey.storage)
            return StoredState()
        }
    }

    private static func defaultImage() -> NSImage {
        let imageSize = NSSize(
            width: MenuBarIconProcessing.standardIconPointSize,
            height: MenuBarIconProcessing.standardIconPointSize
        )
        let image = NSImage(named: defaultIconName) ?? NSImage(size: imageSize)
        image.size = imageSize
        return image
    }

    private func persist() {
        guard let data = try? encoder.encode(storedState) else {
            return
        }

        userDefaults.set(data, forKey: DefaultsKey.storage)
        settingsRevision += 1
    }

    private func renderedFrames(for selection: MenuBarIconLocalSelection) -> MenuBarIconProcessing.PreparedFrames {
        let cacheKey = RenderedFramesCacheKey(
            fileName: selection.fileName,
            frameFileNames: selection.frameFileNames
        )
        if let cachedImages = renderedFramesCache[cacheKey] {
            return cachedImages
        }

        prepareFrames(at: selection.frameFileNames.map { localIconsDirectory.appendingPathComponent($0) }) { [weak self] frames in
            self?.renderedFramesCache[cacheKey] = frames
        }
        return MenuBarIconProcessing.PreparedFrames(images: [], supportsTemplateRendering: false)
    }

    private func renderedImages(for selection: MenuBarIconRemoteAssetSelection) -> [NSImage] {
        let cacheKey = RemoteFramesCacheKey(
            id: selection.id,
            version: selection.version,
            frameFileNames: selection.frameFileNames
        )
        if let cachedImages = remoteFramesCache[cacheKey] {
            return cachedImages
        }

        prepareFrames(at: remoteAssetStore.frameURLs(for: selection)) { [weak self] frames in
            self?.remoteFramesCache[cacheKey] = frames.images
        }
        return []
    }

    private func prepareFrames(at urls: [URL], completion: @escaping (MenuBarIconProcessing.PreparedFrames) -> Void) {
        guard framePreparationTask == nil else { return }
        let revision = framePreparationRevision
        framePreparationTask = Task { @MainActor [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                MenuBarIconProcessing.prepareFrames(at: urls)
            }.value
            guard !Task.isCancelled, let self, self.framePreparationRevision == revision else { return }
            completion(prepared.makeImages())
            self.framePreparationTask = nil
            self.invalidateSelectedIconCaches()
            self.settingsRevision += 1
        }
        #if DEBUG
        if let framePreparationTask { submittedFramePreparations.append(framePreparationTask) }
        #endif
    }

    private func clearRemoteAssetSelection() {
        storedState.remoteAssetSelection = nil
        remoteAssetStore.pruneRemoteAssets(keeping: nil)
    }

    private func saveOriginalImage(_ image: NSImage, to destinationURL: URL) -> Bool {
        guard let data = MenuBarIconProcessing.pngData(from: image) else {
            return false
        }

        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destinationURL, options: .atomic)
            return true
        } catch {
            lastErrorMessage = AppL10n.settings("menuBarIcon.error.saveSettings", defaultValue: "无法保存图标设置。")
            return false
        }
    }

    private func saveAnimationFrames(_ frames: [NSImage], fileNames: [String]) -> Bool {
        guard frames.count == fileNames.count, !frames.isEmpty else {
            return false
        }

        do {
            try fileManager.createDirectory(at: localIconsDirectory, withIntermediateDirectories: true)
            for (frame, fileName) in zip(frames, fileNames) {
                guard let data = MenuBarIconProcessing.pngData(from: frame) else {
                    return false
                }

                let destinationURL = localIconsDirectory.appendingPathComponent(fileName)
                try data.write(to: destinationURL, options: .atomic)
            }

            return true
        } catch {
            lastErrorMessage = AppL10n.settings("menuBarIcon.error.saveAnimationIcon", defaultValue: "无法保存动画图标。")
            return false
        }
    }

    private func resolvedAppearance(from appearance: NSAppearance?) -> MenuBarIconAppearance {
        let bestMatch = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua])
        return bestMatch == .darkAqua ? .dark : .light
    }

    private func pruneMissingLocalIconSelection() {
        guard let selection = storedState.localIconSelection else {
            return
        }

        let hasAllFrames = !selection.frameFileNames.isEmpty
            && selection.frameFileNames.allSatisfy { fileName in
                fileManager.fileExists(atPath: localIconsDirectory.appendingPathComponent(fileName).path)
            }
        guard !hasAllFrames else {
            return
        }

        storedState.localIconSelection = nil
        invalidateAllIconCaches()
        persist()
    }

    private func pruneUnusedLocalIconFiles() {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: localIconsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let referencedFileNames = Set(storedState.localIconSelection?.frameFileNames ?? [])
        for fileURL in fileURLs where !referencedFileNames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func pruneMissingRemoteAssetSelection() {
        guard let selection = storedState.remoteAssetSelection,
              !remoteAssetStore.hasFrames(for: selection)
        else {
            return
        }

        storedState.remoteAssetSelection = nil
        invalidateAllIconCaches()
        remoteAssetStore.pruneRemoteAssets(keeping: nil)
        persist()
    }

    private func invalidateSelectedIconCaches() {
        imagePayloadCache.removeAll()
    }

    private func invalidateAllIconCaches() {
        framePreparationRevision &+= 1
        framePreparationTask?.cancel()
        framePreparationTask = nil
        invalidateSelectedIconCaches()
        renderedFramesCache.removeAll()
        remoteFramesCache.removeAll()
    }
}
