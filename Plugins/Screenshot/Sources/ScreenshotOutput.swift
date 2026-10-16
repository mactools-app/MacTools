import AppKit
import MacToolsPluginKit
import UniformTypeIdentifiers

enum SaveMode { case clipboard, folder, ask }

/// Shared output operations use the enabled plugin's preferences and auxiliary windows.
@MainActor
enum ScreenshotOutput {
    private static var clipboardTask: Task<Void, Never>?

    static func copyToPasteboard(_ png: Data) {
        clipboardTask?.cancel()
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        let revision = pasteboard.changeCount
        clipboardTask = Task {
            guard let tiff = await ScreenshotImageEncoder.tiff(from: png),
                  !Task.isCancelled, pasteboard.changeCount == revision else { return }
            // Never overwrite clipboard content copied while TIFF encoding was in flight.
            pasteboard.addTypes([.tiff], owner: nil)
            pasteboard.setData(tiff, forType: .tiff)
            clipboardTask = nil
        }
    }

    static func save(_ png: Data, mode: SaveMode, environment: ScreenshotEnvironment) {
        switch mode {
        case .clipboard:
            copyToPasteboard(png)
            environment.showToast(environment.string("output.copied", "已复制到剪贴板"))
        case .folder:
            copyToPasteboard(png)
            let url = environment.fileURL(prefix: environment.string("output.screenshotName", "截图"), ext: "png")
            let generation = environment.presentationGeneration
            Task {
                do {
                    _ = try await ScreenshotImageEncoder.writeNew(png, preferred: url)
                    guard generation == environment.presentationGeneration else { return }
                    environment.showToast(environment.format("output.savedAndCopied", "已保存到「%@」，并复制到剪贴板", environment.saveFolderDisplayName))
                } catch {
                    guard generation == environment.presentationGeneration else { return }
                    environment.showToast(environment.format("output.saveFailed", "保存失败：%@", error.localizedDescription))
                }
            }
        case .ask:
            if saveAs(png, suggestedName: suggestedScreenshotName(environment), environment: environment) {
                copyToPasteboard(png)
            }
        }
    }

    static func suggestedScreenshotName(_ environment: ScreenshotEnvironment) -> String {
        "\(environment.string("output.screenshotName", "截图")) \(environment.stamp()).png"
    }

    /// Returns whether the user chose a destination; cancelling must not end the caller's workflow.
    /// `completion` reports whether the file was actually written, so callers can keep their content
    /// available for another attempt after a write failure.
    @discardableResult
    static func saveAs(_ png: Data, suggestedName: String, environment: ScreenshotEnvironment,
                       completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        let panel = NSSavePanel()
        panel.directoryURL = environment.saveFolder
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        environment.savePanel = panel
        defer { if environment.savePanel === panel { environment.savePanel = nil } }
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let generation = environment.presentationGeneration
        Task {
            let written: Bool
            do {
                try await ScreenshotImageEncoder.write(png, to: url)
                written = true
                if generation == environment.presentationGeneration {
                    environment.showToast(environment.format("output.saved", "已保存到「%@」", url.deletingLastPathComponent().lastPathComponent))
                }
            } catch {
                written = false
                if generation == environment.presentationGeneration {
                    environment.showToast(environment.format("output.saveFailed", "保存失败：%@", error.localizedDescription))
                }
            }
            completion?(written)
        }
        return true
    }

    static func finishLong(_ image: CGImage, scale: CGFloat, environment: ScreenshotEnvironment) async {
        let points = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let png: Data
        do { png = try await ScreenshotImageEncoder.png(ScreenshotRaster(image: image, logicalSize: points)) }
        catch {
            if !(error is CancellationError) { environment.showToast(environment.string("output.longExportFailed", "长截图导出失败")) }
            return
        }
        copyToPasteboard(png)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let room = screen.visibleFrame
        let fit = min(1, room.width * 0.85 / points.width, room.height * 0.85 / points.height)
        let size = NSSize(width: points.width * fit, height: points.height * fit)
        environment.pin(png, at: NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2,
                                       width: size.width, height: size.height),
                        bakedShadow: false,
                        name: "\(environment.string("output.longScreenshotName", "长截图")) \(environment.stamp()).png",
                        isResult: true)
        environment.showToast(environment.string("output.longCopiedAndPinned", "已复制到剪贴板，并钉在屏幕上 · ⌘S 保存"))
    }
}
