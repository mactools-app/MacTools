import AppKit
import ScreenCaptureKit
import MacToolsPluginKit

struct WindowSwitcherPreviewCandidate {
    var processID: pid_t
    var frame: CGRect
    var title: String?
    var layer: Int
    var windowID: CGWindowID? = nil
}

/// One active capture, one latest target, and eight short-lived memory previews. No captures are stored on
/// disk, and denied permission never blocks discovery or activation.
@MainActor
final class WindowSwitcherPreview {
    var onChange: ((NSImage?, String?) -> Void)?
    enum Status: Equatable {
        case unavailable, permissionRequired, failed

        func message(using localization: PluginLocalization) -> String {
            switch self {
            case .unavailable:
                localization.string("preview.unavailable", defaultValue: "此窗口暂时无法预览。")
            case .permissionRequired:
                localization.string("preview.permission", defaultValue: "预览需要录屏权限；仍可按标题切换。")
            case .failed:
                localization.string("preview.failed", defaultValue: "无法读取预览；仍可按标题切换。")
            }
        }
    }
    private(set) var currentImage: NSImage?
    private(set) var status: Status?
    var statusMessage: String? { status?.message(using: localization) }

    private struct CacheKey: Hashable {
        var id: String
        var pid: pid_t
        var launchDate: Date?
        var windowNumber: CGWindowID?
        var ownerPID: pid_t
        var previewProcessIdentifiers: Set<pid_t>
        init(_ entry: WindowSwitcherAppEntry) {
            id = entry.id; pid = entry.processIdentifier
            launchDate = entry.applicationLaunchDate; windowNumber = entry.windowNumber
            ownerPID = entry.owningProcessIdentifier
            previewProcessIdentifiers = entry.previewProcessIdentifiers
        }
        func hasSameWindowIdentity(as other: CacheKey) -> Bool {
            id == other.id && pid == other.pid && launchDate == other.launchDate
                && windowNumber == other.windowNumber
        }
    }
    private struct CachedPreview {
        var image: NSImage
        var capturedAt: Date
        var usedAt: Date
    }
    private var cache: [CacheKey: CachedPreview] = [:]
    private var selectedKey: CacheKey?
    private var generation = 0
    private struct Request {
        var entry: WindowSwitcherAppEntry
        var detail: Bool = false
    }
    private var pending: Request?
    private var pendingReady = false
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: Duration
    private var selectedEntry: WindowSwitcherAppEntry?
    private var detailRequested = false
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var pendingWatchdog: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var captureID: UUID?
    private var captureTimedOut = false
    private let captureTimeout: Duration
    private let cacheLifetime: TimeInterval

    private let systemCapture = WindowSwitcherSystemPreviewCapture()
    private let localization: PluginLocalization
    private let hasPermission: @MainActor () -> Bool
    private let capture: @MainActor (WindowSwitcherAppEntry) async throws -> NSImage?
    private let detailCapture: @MainActor (WindowSwitcherAppEntry) async throws -> NSImage?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main), hasPermission: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         captureTimeout: Duration = .seconds(2), cacheLifetime: TimeInterval = 30, debounceDelay: Duration = .milliseconds(80),
         capture: (@MainActor (WindowSwitcherAppEntry) async throws -> NSImage?)? = nil,
         detailCapture: (@MainActor (WindowSwitcherAppEntry) async throws -> NSImage?)? = nil) {
        self.debounceDelay = debounceDelay
        self.captureTimeout = captureTimeout
        self.cacheLifetime = cacheLifetime
        self.localization = localization
        self.hasPermission = hasPermission
        self.capture = capture ?? { [systemCapture] entry in try await systemCapture.capture(entry) }
        self.detailCapture = detailCapture ?? capture ?? { [systemCapture] entry in try await systemCapture.capture(entry, detail: true) }
    }

    deinit {
        task?.cancel(); watchdog?.cancel(); expiryTask?.cancel(); debounceTask?.cancel(); pendingWatchdog?.cancel()
    }

    var isPermissionGranted: Bool { hasPermission() }

    func cancel() {
        generation += 1
        pending = nil; pendingReady = false
        debounceTask?.cancel(); debounceTask = nil
        pendingWatchdog?.cancel(); pendingWatchdog = nil
        selectedKey = nil; selectedEntry = nil; detailRequested = false
        publish(nil)
    }

    func select(_ entry: WindowSwitcherAppEntry?) {
        guard let entry, entry.isWindowEntry, (!entry.metadataUnavailable || entry.windowNumber != nil) else {
            cancel()
            publish(nil, status: .unavailable)
            return
        }
        guard hasPermission() else {
            cache.removeAll()
            systemCapture.invalidate()
            cancel()
            publish(nil, status: .permissionRequired)
            return
        }
        let key = CacheKey(entry)
        selectedEntry = entry
        // Catalog metadata changes do not restart an unchanged selection.
        guard selectedKey != key else { return }
        // Helper authorization changes are part of capture identity. Do not
        // reuse pixels obtained under an older relationship for the same row.
        cache = cache.filter { !$0.key.hasSameWindowIdentity(as: key) || $0.key == key }
        selectedKey = key
        generation += 1
        detailRequested = false
        debounceTask?.cancel(); debounceTask = nil
        pendingWatchdog?.cancel(); pendingWatchdog = nil
        pendingReady = false
        pending = Request(entry: entry)
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.capturedAt) < cacheLifetime }
        if var cached = cache[key] {
            WindowSwitcherPinchDiagnostics.record("preview cache hit generation=\(generation)")
            cached.usedAt = now
            cache[key] = cached
            publish(cached.image)
            if now.timeIntervalSince(cached.capturedAt) < 2 { pending = nil; return }
        } else {
            WindowSwitcherPinchDiagnostics.record("preview cache miss generation=\(generation)")
            publish(nil, status: captureTimedOut ? .unavailable : nil)
        }
        debouncePendingCapture()
    }

    private func debouncePendingCapture() {
        let token = generation, delay = debounceDelay
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == token else { return }
            self.debounceTask = nil
            self.pendingReady = true
            self.startNext()
            self.watchPendingCapture()
        }
    }

    /// Bound feedback for the latest selection even when an older system capture
    /// occupies the serial slot indefinitely. This never releases that slot.
    private func watchPendingCapture() {
        guard pending != nil, task != nil else { return }
        let token = generation, timeout = captureTimeout
        pendingWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == token,
                  let request = self.pending, !request.detail,
                  let key = self.selectedKey, self.cache[key] == nil else { return }
            self.pendingWatchdog = nil
            self.publish(nil, status: .unavailable)
        }
    }

    /// Upgrade only the selected preview, once per selection. Retain the fitted
    /// image while this serial capture runs; large captures never enter the cache.
    func requestDetail() {
        guard !detailRequested, let entry = selectedEntry else { return }
        guard hasPermission() else { select(entry); return }
        detailRequested = true
        generation += 1
        debounceTask?.cancel(); debounceTask = nil
        pendingWatchdog?.cancel(); pendingWatchdog = nil
        pending = Request(entry: entry, detail: true)
        pendingReady = true
        startNext()
    }

    private func publish(_ image: NSImage?, status: Status? = nil) {
        currentImage = image
        self.status = status
        onChange?(image, statusMessage)
    }

    private func startNext() {
        guard task == nil, pendingReady, let request = pending else { return }
        pendingWatchdog?.cancel(); pendingWatchdog = nil
        let entry = request.entry
        pending = nil; pendingReady = false
        let token = generation, id = UUID()
        captureID = id; captureTimedOut = false
        let timeout = captureTimeout
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.captureID == id else { return }
            self.captureTimedOut = true
            if token == self.generation, !request.detail,
               let selectedKey = self.selectedKey, self.cache[selectedKey] == nil {
                self.publish(nil, status: .unavailable)
            }
        }
        // Capture the operation, never the owner, across a potentially suspended
        // system await. Keep the occupied slot until it returns: a timeout must
        // not accumulate orphaned ScreenCaptureKit operations on every selection.
        let capture = request.detail ? self.detailCapture : self.capture
        task = Task { [weak self] in
            for attempt in 0..<3 {
                guard !Task.isCancelled, self?.canCapture(token) == true else { break }
                do {
                    let image = try await capture(entry)
                    guard self?.receive(image, entry: entry, token: token, attempt: attempt, detail: request.detail) == false else { break }
                } catch {
                    guard let owner = self, owner.canCapture(token) else { break }
                    if !request.detail, attempt == 2, owner.cache[CacheKey(entry)] == nil {
                        owner.publish(nil, status: .failed)
                    }
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
            }
            self?.finishCapture(id)
        }
    }

    private func canCapture(_ token: Int) -> Bool {
        token == generation && !captureTimedOut && hasPermission()
    }

    /// Return true when no retry is required. Late or revoked images are discarded.
    private func receive(_ image: NSImage?, entry: WindowSwitcherAppEntry, token: Int, attempt: Int, detail: Bool) -> Bool {
        guard token == generation else { return true }
        guard hasPermission() else {
            cache.removeAll(); systemCapture.invalidate()
            publish(nil, status: .permissionRequired)
            return true
        }
        guard !captureTimedOut else { return true }
        if let image {
            WindowSwitcherPinchDiagnostics.record("preview capture ready generation=\(generation) detail=\(detail)")
            let now = Date()
            if !detail { cache[CacheKey(entry)] = CachedPreview(image: image, capturedAt: now, usedAt: now) }
            while cache.count > 8, let oldest = cache.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
                cache.removeValue(forKey: oldest)
            }
            scheduleExpiry()
            publish(image)
            return true
        }
        if !detail, attempt == 2, cache[CacheKey(entry)] == nil { publish(nil, status: .unavailable) }
        return false
    }

    private func finishCapture(_ id: UUID) {
        guard captureID == id else { return }
        watchdog?.cancel(); watchdog = nil
        task = nil; captureID = nil; captureTimedOut = false
        startNext()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let oldest = cache.values.map(\.capturedAt).min() else { return }
        let delay = max(0, cacheLifetime - Date().timeIntervalSince(oldest))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let now = Date()
            self.cache = self.cache.filter { now.timeIntervalSince($0.value.capturedAt) < self.cacheLifetime }
            self.scheduleExpiry()
        }
    }

    static func matchingIndex(for entry: WindowSwitcherAppEntry, candidates: [WindowSwitcherPreviewCandidate]) -> Int? {
        let relatedProcesses = entry.previewProcessIdentifiers
            .union([entry.processIdentifier, entry.owningProcessIdentifier])
        if let number = entry.windowNumber {
            let exact = candidates.indices.filter {
                candidates[$0].windowID == number && candidates[$0].layer == 0
                    && relatedProcesses.contains(candidates[$0].processID)
            }
            // Window IDs are unique. Helper-owned Chrome windows keep this ID
            // even when the switcher row is attributed to the host app.
            if exact.count == 1 { return exact[0] }
        }
        // Chrome and Steam can expose a compositor surface whose capture ID
        // differs from the AX/WindowServer row. A unique process and geometry
        // match is sufficient; titles can safely disambiguate a helper-owned
        // surface. Never pick by array position or geometry alone.
        let geometry = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.layer == 0 &&
                abs(candidate.frame.minX - entry.bounds.minX) < 2 && abs(candidate.frame.minY - entry.bounds.minY) < 2 &&
                abs(candidate.frame.width - entry.bounds.width) < 2 && abs(candidate.frame.height - entry.bounds.height) < 2
        }
        let sameProcess = geometry.filter { relatedProcesses.contains(candidates[$0].processID) }
        if sameProcess.count == 1 { return sameProcess[0] }
        let titled = geometry.filter {
            guard let expected = entry.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty else { return false }
            return relatedProcesses.contains(candidates[$0].processID)
                && candidates[$0].title?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        }
        return titled.count == 1 ? titled.first : nil
    }

    static func captureSize(for frame: CGRect, detail: Bool = false) -> CGSize {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(2, (detail ? 3200.0 : 1600.0) / max(frame.width, frame.height))
        return CGSize(width: max(1, floor(frame.width * scale)), height: max(1, floor(frame.height * scale)))
    }

}

/// Shares only a short-lived window inventory, not images or a recording stream.
/// Stable window IDs are required for reuse; geometry-only matches use a fresh inventory.
@MainActor
final class WindowSwitcherSystemPreviewCapture {
    private var content: SCShareableContent?
    private var capturedAt = Date.distantPast
    private let now: () -> Date
    private let discover: () async throws -> SCShareableContent
    private let hasPermission: () -> Bool
    private let fallback: (CGWindowID, pid_t, CGSize) async -> CGImage?

    init(now: @escaping () -> Date = Date.init,
         hasPermission: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         fallback: @escaping (CGWindowID, pid_t, CGSize) async -> CGImage? = {
             await WindowSwitcherWindowServer.capture($0, pid: $1, size: $2)
         },
         discover: @escaping () async throws -> SCShareableContent = {
             try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
         }) {
        self.now = now
        self.discover = discover
        self.hasPermission = hasPermission
        self.fallback = fallback
    }

    func invalidate() { content = nil; capturedAt = .distantPast }

    func capture(_ entry: WindowSwitcherAppEntry, detail: Bool = false) async throws -> NSImage? {
        guard hasPermission() else { invalidate(); return nil }
        if let launchDate = entry.applicationLaunchDate,
           NSRunningApplication(processIdentifier: entry.processIdentifier)?.launchDate != launchDate { return nil }
        if content == nil || now().timeIntervalSince(capturedAt) >= 2 || entry.windowNumber == nil {
            do {
                content = try await discover()
                capturedAt = now()
            } catch {
                invalidate()
                if let image = await fallbackCapture(entry, detail: detail) { return image }
                throw error
            }
        }
        guard let content else { return nil }
        let candidates = content.windows.map {
            WindowSwitcherPreviewCandidate(processID: $0.owningApplication?.processID ?? -1,
                frame: $0.frame, title: $0.title, layer: $0.windowLayer, windowID: $0.windowID)
        }
        guard let index = WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates) else {
            invalidate()
            return await fallbackCapture(entry, detail: detail)
        }
        let window = content.windows[index]
        // An offscreen window can be listed by ScreenCaptureKit while its capture
        // stream cannot start. Avoid spending the preview deadline on that stream.
        if !window.isOnScreen, let image = await fallbackCapture(entry, detail: detail) { return image }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let pixels = WindowSwitcherPreview.captureSize(for: window.frame, detail: detail)
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard hasPermission() else { invalidate(); return nil }
            return NSImage(cgImage: image, size: .zero)
        } catch {
            invalidate()
            if let image = await fallbackCapture(entry, detail: detail) { return image }
            throw error
        }
    }

    private func fallbackCapture(_ entry: WindowSwitcherAppEntry, detail: Bool) async -> NSImage? {
        guard let number = entry.windowNumber, hasPermission(), !Task.isCancelled else { return nil }
        let size = WindowSwitcherPreview.captureSize(for: entry.bounds, detail: detail)
        guard let image = await fallback(number, entry.owningProcessIdentifier, size),
              hasPermission(), !Task.isCancelled else { return nil }
        if let launchDate = entry.applicationLaunchDate,
           NSRunningApplication(processIdentifier: entry.processIdentifier)?.launchDate != launchDate { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
