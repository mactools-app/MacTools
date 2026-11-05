import AppKit
import MacToolsPluginKit
import SwiftUI

struct ClipboardEmbeddedPreviewKey: Hashable {
    let itemID: UUID
    let payloadDigest: Data

    init(_ item: ClipboardHistoryItem) {
        itemID = item.id
        payloadDigest = item.payloadDigest
    }
}

/// Bounded decoded thumbnails reused across ordinary window closes. Never retains source clipboard payloads.
@MainActor
final class ClipboardEmbeddedPreviewCache {
    private struct Entry {
        let image: NSImage
        let cost: Int
        var access: UInt64
    }
    private struct Flight {
        let id: UUID
        let task: Task<ClipboardEmbeddedPreviewResult, Never>
        var consumers: Set<UUID>
    }

    private let maximumCost: Int
    private let maximumCount: Int
    private let loader: @MainActor (ClipboardHistoryItem) async -> ClipboardEmbeddedPreviewResult
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var entries: [ClipboardEmbeddedPreviewKey: Entry] = [:]
    private var flights: [ClipboardEmbeddedPreviewKey: Flight] = [:]
    private var access: UInt64 = 0
    private(set) var totalCost = 0
    var count: Int { entries.count }

    // Each cache has one decode size. Row thumbnails never replace larger detail previews.
    init(maximumCost: Int = 32 * 1_024 * 1_024, maximumCount: Int = 8,
         maximumThumbnailDimension: Int = ClipboardEmbeddedPreviewPolicy.maximumThumbnailDimension,
         loader: (@MainActor (ClipboardHistoryItem) async -> NSImage?)? = nil) {
        self.maximumCost = max(0, maximumCost)
        self.maximumCount = max(0, maximumCount)
        self.loader = { item in
            if let loader { return .init(image: await loader(item)) }
            return await ClipboardEmbeddedPreviewLoader.loadResult(
                for: item, maximumThumbnailDimension: maximumThumbnailDimension
            )
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.removeAll() }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit { memoryPressureSource?.cancel() }

    static func rowThumbnails() -> ClipboardEmbeddedPreviewCache {
        ClipboardEmbeddedPreviewCache(
            maximumCost: 8 * 1_024 * 1_024, maximumCount: 64,
            maximumThumbnailDimension: 240
        )
    }

    func cachedImage(for item: ClipboardHistoryItem) -> NSImage? {
        let key = ClipboardEmbeddedPreviewKey(item)
        guard var entry = entries[key] else { return nil }
        access &+= 1
        entry.access = access
        entries[key] = entry
        return entry.image
    }

    func image(for item: ClipboardHistoryItem) async -> NSImage? {
        await result(for: item).image
    }

    func result(for item: ClipboardHistoryItem) async -> ClipboardEmbeddedPreviewResult {
        guard !Task.isCancelled else { return .init(image: nil, failure: .cancelled) }
        if let cached = cachedImage(for: item) { return .init(image: cached) }
        let key = ClipboardEmbeddedPreviewKey(item)
        let consumer = UUID()
        let flight: Flight
        if var existing = flights[key] {
            existing.consumers.insert(consumer)
            flights[key] = existing
            flight = existing
        } else {
            let loader = loader
            flight = Flight(id: UUID(), task: Task {
                await loader(item)
            }, consumers: [consumer])
            flights[key] = flight
        }
        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(consumer: consumer, key: key, flightID: flight.id) }
        }
        guard !Task.isCancelled else {
            cancel(consumer: consumer, key: key, flightID: flight.id)
            return .init(image: nil, failure: .cancelled)
        }
        // Keep the flight until every consumer has resumed, including images too
        // large to cache. Invalidation removes it and rejects all late results.
        guard var active = flights[key], active.id == flight.id else { return .init(image: nil, failure: .cancelled) }
        active.consumers.remove(consumer)
        if active.consumers.isEmpty { flights.removeValue(forKey: key) }
        else { flights[key] = active }
        if entries[key] == nil, let image = result.image { insert(image, for: key) }
        return result
    }

    func retain(where isValid: (ClipboardEmbeddedPreviewKey) -> Bool) {
        for key in Array(entries.keys) where !isValid(key) {
            totalCost -= entries.removeValue(forKey: key)?.cost ?? 0
        }
        for key in Array(flights.keys) where !isValid(key) {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    func cancelPendingLoads() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    func removeAll() {
        cancelPendingLoads()
        entries.removeAll()
        totalCost = 0
    }

    private func cancel(consumer: UUID, key: ClipboardEmbeddedPreviewKey, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private func insert(_ image: NSImage, for key: ClipboardEmbeddedPreviewKey) {
        let width = image.representations.map { Double($0.pixelsWide) }.max() ?? Double(image.size.width)
        let height = image.representations.map { Double($0.pixelsHigh) }.max() ?? Double(image.size.height)
        // Conservatively budget eight bytes per pixel, including high-bit-depth images.
        let cost = width * height * 8
        guard maximumCount > 0, width > 0, height > 0,
              cost.isFinite, cost > 0, cost < Double(Int.max), cost <= Double(maximumCost) else { return }
        if let previous = entries.removeValue(forKey: key) { totalCost -= previous.cost }
        while entries.count >= maximumCount || totalCost + Int(cost) > maximumCost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            totalCost -= entries.removeValue(forKey: oldest)?.cost ?? 0
        }
        access &+= 1
        entries[key] = Entry(image: image, cost: Int(cost), access: access)
        totalCost += Int(cost)
    }
}

/// Each preview leaf owns its loading state, including generation checks for
/// cancelled/deleted content. Failures are not cached, so Retry performs a new read.
@MainActor
final class ClipboardEmbeddedPreviewPresentation: ObservableObject {
    enum State {
        case loading
        case ready(NSImage)
        case failed(ClipboardEmbeddedPreviewFailure)
    }

    @Published private(set) var state: State = .loading
    private var generation: UInt = 0

    func reset() {
        generation &+= 1
        state = .loading
    }

    func load(_ item: ClipboardHistoryItem, cache: ClipboardEmbeddedPreviewCache) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let request = generation
        if let cached = cache.cachedImage(for: item) {
            state = .ready(cached)
            return
        }
        state = .loading
        guard await ClipboardPreviewLoadPolicy.waitForSelection(), generation == request else { return }
        let result = await cache.result(for: item)
        guard !Task.isCancelled, generation == request else { return }
        if let image = result.image { state = .ready(image) }
        else { state = .failed(result.failure) }
    }
}

struct ClipboardEmbeddedPreviewView<Content: View, Unavailable: View>: View {
    let item: ClipboardHistoryItem
    let cache: ClipboardEmbeddedPreviewCache
    let loadingTitle: String
    let retryTitle: String
    var resetID: UInt = 0
    var isActive = true
    @ViewBuilder let content: (NSImage) -> Content
    @ViewBuilder let unavailable: (ClipboardEmbeddedPreviewFailure) -> Unavailable
    @StateObject private var presentation = ClipboardEmbeddedPreviewPresentation()
    @State private var retryID: UInt = 0

    var body: some View {
        Group {
            switch presentation.state {
            case .loading:
                ProgressView(loadingTitle)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            case let .ready(image):
                content(image)
            case let .failed(reason):
                VStack(spacing: 12) {
                    unavailable(reason)
                    Button(retryTitle) { retryID &+= 1 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: ClipboardEmbeddedPreviewRequestID(
            key: ClipboardEmbeddedPreviewKey(item), resetID: resetID,
            retryID: retryID, isActive: isActive
        )) {
            guard isActive else { presentation.reset(); return }
            await presentation.load(item, cache: cache)
        }
        .onChange(of: isActive) { _, active in
            if !active { presentation.reset() }
        }
    }
}

private struct ClipboardEmbeddedPreviewRequestID: Hashable {
    let key: ClipboardEmbeddedPreviewKey
    let resetID: UInt
    let retryID: UInt
    let isActive: Bool
}

struct ClipboardHistoryRowThumbnail: View {
    private static let size = CGSize(width: 96, height: 56)

    let item: ClipboardHistoryItem
    let cache: ClipboardEmbeddedPreviewCache
    let resetID: UInt
    let isActive: Bool
    @StateObject private var presentation = ClipboardEmbeddedPreviewPresentation()
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if case let .ready(image) = presentation.state {
                let size = ClipboardImagePreviewLayout.aspectFitSize(
                    contentSize: image.size, containerSize: Self.size, padding: 0
                )
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .background(PluginSettingsTheme.Palette.recessedControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                contrast == .increased ? Color.primary : PluginSettingsTheme.Palette.cardBorder,
                                lineWidth: 1
                            )
                    }
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        // Reserve a stable column while loading, but draw the surface only around the image.
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: ClipboardEmbeddedPreviewRequestID(
            key: ClipboardEmbeddedPreviewKey(item), resetID: resetID,
            retryID: 0, isActive: isActive
        )) {
            guard isActive else { presentation.reset(); return }
            await presentation.load(item, cache: cache)
        }
        .onChange(of: isActive) { _, active in
            if !active { presentation.reset() }
        }
    }
}
