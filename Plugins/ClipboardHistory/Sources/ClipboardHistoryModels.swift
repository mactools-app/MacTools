import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ClipboardSourceApplication: Codable, Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
}

struct ClipboardExcludedApplication: Codable, Equatable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

enum ClipboardExcludedApplicationDisplayName {
    static func fallbackLocalizationKey(for bundleIdentifier: String) -> String? {
        switch bundleIdentifier.lowercased() {
        case "com.apple.passwords":
            "excludedApplication.passwords"
        case "com.apple.keychainaccess":
            "excludedApplication.keychainAccess"
        default:
            nil
        }
    }

    static func resolve(
        application: ClipboardExcludedApplication,
        installedLocalizedName: String?,
        localizedFallback: (String) -> String?
    ) -> String {
        if let installedLocalizedName, !installedLocalizedName.isEmpty {
            return installedLocalizedName
        }
        guard let key = fallbackLocalizationKey(for: application.bundleIdentifier),
              let fallback = localizedFallback(key),
              !fallback.isEmpty else {
            return application.name
        }
        return fallback
    }
}

enum ClipboardRepresentationType {
    static let plainText = "public.utf8-plain-text"
    static let rtf = "public.rtf"
    static let rtfd = "com.apple.flat-rtfd"
    static let html = "public.html"
    static let png = "public.png"
    static let tiff = "public.tiff"
    static let pdf = "com.adobe.pdf"
    static let fileURL = "public.file-url"
    static let url = "public.url"
    static let color = "com.apple.cocoa.pasteboard.color"
    static let sound = "com.apple.cocoa.pasteboard.sound"

    private static let exactSupportedTypes: Set<String> = [
        plainText,
        rtf,
        rtfd,
        html,
        png,
        tiff,
        pdf,
        fileURL,
        url,
        color,
        sound,
    ]

    static func isSupported(_ typeIdentifier: String) -> Bool {
        if exactSupportedTypes.contains(typeIdentifier) {
            return true
        }
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .image)
            || type.conforms(to: .audio)
            || type.conforms(to: .movie)
    }

    static func isImage(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .image)
    }

    static func isMedia(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}

struct ClipboardStoredRepresentation: Codable, Equatable, Sendable {
    let typeIdentifier: String
    let data: Data
}

struct ClipboardStoredPasteboardItem: Codable, Equatable, Sendable {
    let representations: [ClipboardStoredRepresentation]
}

enum ClipboardHistoryContentKind: String, Codable, Equatable, Sendable {
    case plainText
    case richText
    case image
    case pdf
    case files
    case link
    case color
    case media
}

enum ClipboardHistorySemanticTrait: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case link
    case email
    case recognizedText
    case color
}

enum ClipboardHistorySemanticClassification {
    static func traits(
        text: String,
        linkURLs: [URL],
        imageSearchText: String?
    ) -> Set<ClipboardHistorySemanticTrait> {
        var result = Set<ClipboardHistorySemanticTrait>()
        let recognizedText = imageSearchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchableText = [text, recognizedText]
            .compactMap { $0 }
            .joined(separator: "\n")

        if !linkURLs.isEmpty || containsWebLink(in: searchableText) {
            result.insert(.link)
        }
        if containsEmailAddress(in: searchableText) {
            result.insert(.email)
        }
        if recognizedText?.isEmpty == false {
            result.insert(.recognizedText)
        }
        // Color is a primary type, not a general "contains" trait. In particular,
        // OCR issue numbers such as #351 must not turn a screenshot into a color.
        if ClipboardColorValue(hex: text) != nil {
            result.insert(.color)
        }
        return result
    }

    private static func containsWebLink(in text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).contains { rawToken in
            let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
            guard !token.isEmpty else { return false }
            let lowercase = token.lowercased()
            if lowercase.hasPrefix("www.") {
                return lowercase.dropFirst(4).contains(".")
            }
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return false
            }
            return url.host?.isEmpty == false
        }
    }

    private static func containsEmailAddress(in text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).contains { rawToken in
            let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
            let parts = token.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[1].contains("."),
                  !parts[1].hasPrefix("."),
                  !parts[1].hasSuffix(".") else {
                return false
            }
            let allowedLocal = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: ".!#$%&'*+-/=?^_`{|}~")
            )
            let allowedDomain = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: ".-")
            )
            return parts[0].unicodeScalars.allSatisfy(allowedLocal.contains)
                && parts[1].unicodeScalars.allSatisfy(allowedDomain.contains)
        }
    }
}

enum ClipboardFileContentKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case pdf
    case image
    case audio
    case video

    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else {
            return nil
        }
    }

    var contentKind: ClipboardHistoryContentKind {
        switch self {
        case .pdf: .pdf
        case .image: .image
        case .audio, .video: .media
        }
    }
}

struct ClipboardHistoryPayload: Codable, Equatable, Sendable {
    static let maximumMetadataURLByteCount = 4_096
    static let maximumMetadataFileURLCount = 32
    static let maximumMetadataLinkURLCount = 32
    static let maximumMetadataRepresentationTypeCount = 64
    static let maximumMetadataRepresentationTypeCharacterCount = 256

    let pasteboardItems: [ClipboardStoredPasteboardItem]

    init(pasteboardItems: [ClipboardStoredPasteboardItem]) {
        self.pasteboardItems = pasteboardItems.filter { !$0.representations.isEmpty }
    }

    static func plainText(_ text: String) -> Self {
        Self(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data(text.utf8)
                ),
            ]),
        ])
    }

    var representations: [ClipboardStoredRepresentation] {
        pasteboardItems.flatMap(\.representations)
    }

    var byteCount: Int {
        representations.reduce(0) { $0 + $1.data.count }
    }

    var plainTexts: [String] {
        representations
            .filter { $0.typeIdentifier == ClipboardRepresentationType.plainText }
            .compactMap { String(data: $0.data, encoding: .utf8) }
    }

    var plainText: String? { plainTexts.first }

    var hasSinglePlainTextRepresentation: Bool {
        pasteboardItems.count == 1
            && pasteboardItems[0].representations.count == 1
            && pasteboardItems[0].representations[0].typeIdentifier == ClipboardRepresentationType.plainText
    }

    var fileURLs: [URL] {
        representations.compactMap { representation in
            guard representation.typeIdentifier == ClipboardRepresentationType.fileURL,
                  let value = String(data: representation.data, encoding: .utf8) else {
                return nil
            }
            return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// File-reference metadata is loaded for every history row. Keep both the URL count and each
    /// encoded URL bounded; complete references remain available in the lazy encrypted payload.
    var metadataFileURLs: [URL] {
        representations.lazy
            .filter { $0.typeIdentifier == ClipboardRepresentationType.fileURL }
            .prefix(Self.maximumMetadataFileURLCount)
            .compactMap { representation in
                let boundedData = representation.data.prefix(Self.maximumMetadataURLByteCount)
                guard let value = String(data: boundedData, encoding: .utf8) else { return nil }
                return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    var linkURLs: [URL] {
        representations.compactMap { representation in
            guard representation.typeIdentifier == ClipboardRepresentationType.url,
                  let value = String(data: representation.data, encoding: .utf8) else {
                return nil
            }
            return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Link metadata is loaded eagerly for every history row. Keep it bounded; the complete URL
    /// remains in the encrypted payload and is decoded only when the item is used.
    var metadataLinkURLs: [URL] {
        representations.lazy
            .filter { $0.typeIdentifier == ClipboardRepresentationType.url }
            .prefix(Self.maximumMetadataLinkURLCount)
            .compactMap { representation in
                let boundedData = representation.data.prefix(Self.maximumMetadataURLByteCount)
                guard let value = String(data: boundedData, encoding: .utf8) else { return nil }
                return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    var metadataRepresentationTypeIdentifiers: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for representation in representations {
            let typeIdentifier = String(representation.typeIdentifier.prefix(
                Self.maximumMetadataRepresentationTypeCharacterCount
            ))
            guard !typeIdentifier.isEmpty, seen.insert(typeIdentifier).inserted else { continue }
            result.append(typeIdentifier)
            if result.count == Self.maximumMetadataRepresentationTypeCount { break }
        }
        return result
    }

    var fileContentKinds: Set<ClipboardFileContentKind> {
        Set(fileURLs.compactMap(ClipboardFileContentKind.init(url:)))
    }

    /// Types used for discovery and filtering. A Finder file remains a native
    /// file-reference payload while also appearing in its semantic type filter.
    var filterContentKinds: Set<ClipboardHistoryContentKind> {
        let types = representations.map(\.typeIdentifier)
        var kinds: Set<ClipboardHistoryContentKind> = [kind]

        if !fileURLs.isEmpty {
            kinds.insert(.files)
            kinds.formUnion(fileContentKinds.map(\.contentKind))
        }
        if types.contains(where: ClipboardRepresentationType.isImage) {
            kinds.insert(.image)
        }
        if types.contains(ClipboardRepresentationType.pdf) {
            kinds.insert(.pdf)
        }
        if types.contains(ClipboardRepresentationType.rtf)
            || types.contains(ClipboardRepresentationType.rtfd)
            || types.contains(ClipboardRepresentationType.html) {
            kinds.insert(.richText)
        }
        if types.contains(where: ClipboardRepresentationType.isMedia)
            || types.contains(ClipboardRepresentationType.sound) {
            kinds.insert(.media)
        }
        if types.contains(ClipboardRepresentationType.color) {
            kinds.insert(.color)
        }
        if types.contains(ClipboardRepresentationType.url) {
            kinds.insert(.link)
        }
        if types.contains(ClipboardRepresentationType.plainText) {
            kinds.insert(.plainText)
        }
        return kinds
    }

    var searchableText: String {
        let textValues = plainTexts.filter { !$0.isEmpty }
            + metadataLinkURLs.map(\.absoluteString).filter { !$0.isEmpty }
        if !textValues.isEmpty {
            return Array(NSOrderedSet(array: textValues)).compactMap { $0 as? String }
                .joined(separator: "\n")
        }
        let fileNames = fileURLs.map(\.lastPathComponent).filter { !$0.isEmpty }
        return fileNames.joined(separator: "\n")
    }

    var kind: ClipboardHistoryContentKind {
        let types = representations.map(\.typeIdentifier)
        if types.contains(ClipboardRepresentationType.fileURL) {
            return .files
        }
        if types.contains(where: ClipboardRepresentationType.isImage) {
            return .image
        }
        if types.contains(ClipboardRepresentationType.pdf) {
            return .pdf
        }
        if types.contains(ClipboardRepresentationType.rtf)
            || types.contains(ClipboardRepresentationType.rtfd)
            || types.contains(ClipboardRepresentationType.html) {
            return .richText
        }
        if types.contains(where: ClipboardRepresentationType.isMedia)
            || types.contains(ClipboardRepresentationType.sound) {
            return .media
        }
        if types.contains(ClipboardRepresentationType.color) {
            return .color
        }
        if types.contains(ClipboardRepresentationType.url) {
            return .link
        }
        return .plainText
    }
}

struct ClipboardHistorySearchIndex: Equatable, Sendable {
    let normalizedText: String
    let tokens: [String]
}

enum ClipboardHistoryPayloadAccessError: Error, Sendable {
    case unavailable
}

final class ClipboardHistoryPayloadReference: @unchecked Sendable {
    /// Each reader keeps its load's result independently of the evictable cache.
    /// Access to this result is protected by the reference's condition lock.
    private final class Load: @unchecked Sendable {
        var result: Result<ClipboardHistoryPayload, any Error>?
    }

    private let condition = NSCondition()
    private var cachedPayload: ClipboardHistoryPayload?
    private var loader: (@Sendable () throws -> ClipboardHistoryPayload)?
    private var activeLoad: Load?
    private var waitingLoaderCount = 0
    private var asyncWaiters: [UUID: CheckedContinuation<ClipboardHistoryPayload, any Error>] = [:]
    private var cachePublicationRevision: UInt64 = 0
    private var loaderRevision: UInt64 = 0

    init(payload: ClipboardHistoryPayload) {
        cachedPayload = payload
        loader = nil
    }

    init(loader: @escaping @Sendable () throws -> ClipboardHistoryPayload) {
        cachedPayload = nil
        self.loader = loader
    }

    var cached: ClipboardHistoryPayload? {
        condition.withLock { cachedPayload }
    }

    var isCached: Bool {
        condition.withLock { cachedPayload != nil }
    }

    var isLoadingForTesting: Bool { condition.withLock { activeLoad != nil } }

    func loadAsync() async throws -> ClipboardHistoryPayload {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                if Task.isCancelled {
                    condition.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let cachedPayload {
                    condition.unlock()
                    continuation.resume(returning: cachedPayload)
                    return
                }
                guard let loader else {
                    condition.unlock()
                    continuation.resume(throwing: ClipboardHistoryPayloadAccessError.unavailable)
                    return
                }
                asyncWaiters[waiterID] = continuation
                let shouldStartLoading = activeLoad == nil
                let load = activeLoad ?? Load()
                let publicationRevision = cachePublicationRevision
                let currentLoaderRevision = loaderRevision
                if shouldStartLoading {
                    activeLoad = load
                }
                condition.unlock()

                if shouldStartLoading {
                    Task.detached(priority: .userInitiated) { [weak self] in
                        self?.finishLoading(
                            Result { try loader() }, load: load,
                            publicationRevision: publicationRevision, loaderRevision: currentLoaderRevision
                        )
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.cancelAsyncWaiter(id: waiterID)
        }
    }

    func load() throws -> ClipboardHistoryPayload {
        guard !Task.isCancelled else { throw CancellationError() }

        condition.lock()
        if let cachedPayload {
            condition.unlock()
            return cachedPayload
        }
        guard let loader else {
            condition.unlock()
            throw ClipboardHistoryPayloadAccessError.unavailable
        }

        if let load = activeLoad {
            waitingLoaderCount += 1
            defer {
                waitingLoaderCount -= 1
                if Task.isCancelled, waitingLoaderCount == 0, asyncWaiters.isEmpty {
                    cachePublicationRevision &+= 1
                }
                condition.unlock()
            }
            while true {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if let result = load.result {
                    return try result.get()
                }
                condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        let load = Load()
        activeLoad = load
        let publicationRevision = cachePublicationRevision
        let currentLoaderRevision = loaderRevision
        condition.unlock()

        let result = Result { try loader() }
        if Task.isCancelled {
            condition.withLock { cachePublicationRevision &+= 1 }
        }
        finishLoading(result, load: load, publicationRevision: publicationRevision, loaderRevision: currentLoaderRevision)

        guard !Task.isCancelled else { throw CancellationError() }
        return try result.get()
    }

    private func finishLoading(
        _ result: Result<ClipboardHistoryPayload, any Error>,
        load: Load,
        publicationRevision: UInt64,
        loaderRevision: UInt64
    ) {
        condition.lock()
        activeLoad = nil
        load.result = result
        if case let .success(payload) = result {
            // A discarded load may still serve surviving consumers, but must not retain
            // decrypted data after its last consumer has cancelled or released it.
            if self.loaderRevision == loaderRevision,
               cachePublicationRevision == publicationRevision
                || !asyncWaiters.isEmpty || waitingLoaderCount > 0 {
                cachedPayload = payload
            }
        }
        let waiters = asyncWaiters.values
        asyncWaiters.removeAll()
        condition.broadcast()
        condition.unlock()

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func cancelAsyncWaiter(id: UUID) {
        let waiter = condition.withLock {
            let waiter = asyncWaiters.removeValue(forKey: id)
            if waiter != nil, asyncWaiters.isEmpty, waitingLoaderCount == 0 {
                cachePublicationRevision &+= 1
            }
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    func configureLoader(
        _ loader: @escaping @Sendable () throws -> ClipboardHistoryPayload,
        discardCachedPayload: Bool
    ) {
        condition.withLock {
            self.loader = loader
            loaderRevision &+= 1
            if discardCachedPayload {
                cachePublicationRevision &+= 1
                cachedPayload = nil
            }
        }
    }

    func discardCachedPayloadIfReloadable() {
        condition.withLock {
            guard loader != nil else { return }
            cachePublicationRevision &+= 1
            cachedPayload = nil
        }
    }

    var waitingLoaderCountForTesting: Int {
        condition.withLock { waitingLoaderCount + asyncWaiters.count }
    }
}

struct ClipboardHistorySavedMetadata: Codable, Equatable, Sendable {
    var title: String
    var tags: [String]
    let savedAt: Date
    var updatedAt: Date

    init(
        title: String,
        tags: [String] = [],
        savedAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.title = title
        self.tags = tags
        self.savedAt = savedAt
        self.updatedAt = updatedAt ?? savedAt
    }
}

struct ClipboardHistoryItem: Codable, Equatable, Identifiable, Sendable {
    static let maximumSearchableCharacterCount = 4_096

    let id: UUID
    private let payloadReference: ClipboardHistoryPayloadReference
    let text: String
    let capturedAt: Date
    let source: ClipboardHistorySource
    var sourceApplication: ClipboardSourceApplication? { source.application }
    let kind: ClipboardHistoryContentKind
    let payloadByteCount: Int
    let filterContentKinds: Set<ClipboardHistoryContentKind>
    let fileURLs: [URL]
    let fileReferenceCount: Int
    let linkURLs: [URL]
    let representationTypeIdentifiers: [String]
    let hasSinglePlainTextRepresentation: Bool?
    var isPlainTextOnly: Bool { hasSinglePlainTextRepresentation == true }
    private(set) var semanticTraits: Set<ClipboardHistorySemanticTrait>
    let payloadDigest: Data
    let allowsRichTextImport: Bool
    let textCharacterCount: Int
    let textLineCount: Int
    let isSearchTextTruncated: Bool
    var isInHistory: Bool
    private(set) var savedMetadata: ClipboardHistorySavedMetadata?
    /// Compatibility surface for pre-release callers. History no longer has a pin state; durable
    /// user-owned content belongs in the Saved Library instead.
    var isPinned: Bool { false }
    var lastUsedAt: Date?
    private(set) var imageSearchText: String?
    var hasCompletedImageTextIndexing: Bool
    private(set) var searchIndex: ClipboardHistorySearchIndex

    init(
        id: UUID,
        payload: ClipboardHistoryPayload,
        capturedAt: Date,
        sourceApplication: ClipboardSourceApplication?,
        isPinned _: Bool,
        lastUsedAt: Date?,
        imageSearchText: String? = nil,
        hasCompletedImageTextIndexing: Bool = false,
        isInHistory: Bool = true,
        savedMetadata: ClipboardHistorySavedMetadata? = nil,
        precomputedPayloadDigest: Data? = nil,
        source: ClipboardHistorySource? = nil
    ) {
        self.id = id
        payloadReference = ClipboardHistoryPayloadReference(payload: payload)
        let searchableText = payload.searchableText
        text = String(searchableText.prefix(Self.maximumSearchableCharacterCount))
        self.capturedAt = capturedAt
        self.source = source ?? ClipboardHistorySource(application: sourceApplication)
        kind = payload.kind
        payloadByteCount = payload.byteCount
        filterContentKinds = payload.filterContentKinds
        let completeFileURLs = payload.fileURLs
        fileURLs = payload.metadataFileURLs
        fileReferenceCount = completeFileURLs.count
        linkURLs = payload.metadataLinkURLs
        representationTypeIdentifiers = payload.metadataRepresentationTypeIdentifiers
        hasSinglePlainTextRepresentation = payload.hasSinglePlainTextRepresentation
        payloadDigest = precomputedPayloadDigest ?? Self.digest(payload)
        allowsRichTextImport = ClipboardRichTextPreviewPolicy.allowsFormattedImport(payload)
        textCharacterCount = searchableText.count
        textLineCount = Self.lineCount(searchableText)
        isSearchTextTruncated = searchableText.count > Self.maximumSearchableCharacterCount
        self.isInHistory = isInHistory
        self.savedMetadata = savedMetadata
        self.lastUsedAt = lastUsedAt
        let boundedImageSearchText = imageSearchText.map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        self.imageSearchText = boundedImageSearchText
        self.hasCompletedImageTextIndexing = hasCompletedImageTextIndexing
        semanticTraits = ClipboardHistorySemanticClassification.traits(
            text: text,
            linkURLs: payload.metadataLinkURLs,
            imageSearchText: boundedImageSearchText
        )
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(text: text, savedMetadata: savedMetadata),
            sourceApplication: self.source.application,
            fileURLs: payload.metadataFileURLs,
            linkURLs: payload.metadataLinkURLs,
            imageSearchText: boundedImageSearchText
        )
    }

    init(
        id: UUID,
        text: String,
        capturedAt: Date,
        sourceApplication: ClipboardSourceApplication?,
        isPinned _: Bool,
        lastUsedAt: Date?,
        isInHistory: Bool = true,
        savedMetadata: ClipboardHistorySavedMetadata? = nil
    ) {
        self.init(
            id: id,
            payload: .plainText(text),
            capturedAt: capturedAt,
            sourceApplication: sourceApplication,
            isPinned: false,
            lastUsedAt: lastUsedAt,
            isInHistory: isInHistory,
            savedMetadata: savedMetadata
        )
    }

    var payload: ClipboardHistoryPayload? { payloadReference.cached }

    var fileContentKinds: Set<ClipboardFileContentKind> {
        Set(fileURLs.compactMap(ClipboardFileContentKind.init(url:)))
    }

    func loadPayload() throws -> ClipboardHistoryPayload {
        try payloadReference.load()
    }

    func loadPayloadAsync() async throws -> ClipboardHistoryPayload {
        try await payloadReference.loadAsync()
    }

    var waitingPayloadLoaderCountForTesting: Int {
        payloadReference.waitingLoaderCountForTesting
    }

    func configurePayloadLoader(
        _ loader: @escaping @Sendable () throws -> ClipboardHistoryPayload,
        discardCachedPayload: Bool
    ) {
        payloadReference.configureLoader(loader, discardCachedPayload: discardCachedPayload)
    }

    func discardCachedPayloadIfReloadable() {
        payloadReference.discardCachedPayloadIfReloadable()
    }

    init(
        id: UUID,
        text: String,
        capturedAt: Date,
        sourceApplication: ClipboardSourceApplication?,
        kind: ClipboardHistoryContentKind,
        payloadByteCount: Int,
        filterContentKinds: Set<ClipboardHistoryContentKind>,
        fileURLs: [URL],
        fileReferenceCount: Int? = nil,
        linkURLs: [URL] = [],
        representationTypeIdentifiers: [String],
        hasSinglePlainTextRepresentation: Bool? = nil,
        semanticTraits: Set<ClipboardHistorySemanticTrait>? = nil,
        searchIndex: ClipboardHistorySearchIndex? = nil,
        payloadDigest: Data,
        allowsRichTextImport: Bool,
        textCharacterCount: Int,
        textLineCount: Int,
        isSearchTextTruncated: Bool,
        isPinned _: Bool,
        lastUsedAt: Date?,
        imageSearchText: String?,
        hasCompletedImageTextIndexing: Bool,
        isInHistory: Bool = true,
        savedMetadata: ClipboardHistorySavedMetadata? = nil,
        source: ClipboardHistorySource? = nil,
        payloadLoader: @escaping @Sendable () throws -> ClipboardHistoryPayload
    ) {
        self.id = id
        payloadReference = ClipboardHistoryPayloadReference(loader: payloadLoader)
        let boundedText = String(text.prefix(Self.maximumSearchableCharacterCount))
        self.text = boundedText
        self.capturedAt = capturedAt
        self.source = source ?? ClipboardHistorySource(application: sourceApplication)
        self.kind = kind
        self.payloadByteCount = payloadByteCount
        self.filterContentKinds = filterContentKinds
        self.fileURLs = fileURLs
        self.fileReferenceCount = max(fileURLs.count, fileReferenceCount ?? fileURLs.count)
        self.linkURLs = linkURLs
        self.representationTypeIdentifiers = representationTypeIdentifiers
        self.hasSinglePlainTextRepresentation = hasSinglePlainTextRepresentation
        let boundedImageSearchText = imageSearchText.map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        self.semanticTraits = semanticTraits ?? ClipboardHistorySemanticClassification.traits(
            text: boundedText,
            linkURLs: linkURLs,
            imageSearchText: boundedImageSearchText
        )
        self.payloadDigest = payloadDigest
        self.allowsRichTextImport = allowsRichTextImport
        self.textCharacterCount = textCharacterCount
        self.textLineCount = textLineCount
        self.isSearchTextTruncated = isSearchTextTruncated
            || text.count > Self.maximumSearchableCharacterCount
        self.isInHistory = isInHistory
        self.savedMetadata = savedMetadata
        self.lastUsedAt = lastUsedAt
        self.imageSearchText = boundedImageSearchText
        self.hasCompletedImageTextIndexing = hasCompletedImageTextIndexing
        self.searchIndex = searchIndex ?? ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(text: boundedText, savedMetadata: savedMetadata),
            sourceApplication: self.source.application,
            fileURLs: fileURLs,
            linkURLs: linkURLs,
            imageSearchText: boundedImageSearchText
        )
    }

    mutating func setImageSearchText(_ recognizedText: String?) {
        let boundedText = recognizedText.map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        imageSearchText = boundedText
        semanticTraits = ClipboardHistorySemanticClassification.traits(
            text: text,
            linkURLs: linkURLs,
            imageSearchText: boundedText
        )
        refreshSearchIndex()
    }

    var isSaved: Bool { savedMetadata != nil }

    /// Latest capture or reuse, shared by presentation and inactivity expiration.
    var lastActivityAt: Date {
        max(capturedAt, lastUsedAt ?? capturedAt)
    }

    var savedActivityAt: Date? {
        guard let savedMetadata else { return nil }
        return max(savedMetadata.updatedAt, lastUsedAt ?? .distantPast)
    }

    mutating func setSavedMetadata(_ metadata: ClipboardHistorySavedMetadata?) {
        savedMetadata = metadata
        refreshSearchIndex()
    }

    mutating func updateSavedMetadata(title: String, tags: [String], updatedAt: Date) {
        guard var metadata = savedMetadata else { return }
        metadata.title = title
        metadata.tags = tags
        metadata.updatedAt = updatedAt
        savedMetadata = metadata
        refreshSearchIndex()
    }

    mutating func setHistoryMembership(_ isInHistory: Bool) {
        self.isInHistory = isInHistory
    }

    func recaptured(from capturedItem: ClipboardHistoryItem) -> ClipboardHistoryItem? {
        guard let payload = try? capturedItem.loadPayload() else { return nil }
        return ClipboardHistoryItem(
            id: id,
            payload: payload,
            capturedAt: capturedItem.capturedAt,
            sourceApplication: capturedItem.sourceApplication,
            isPinned: false,
            lastUsedAt: lastUsedAt,
            imageSearchText: capturedItem.imageSearchText,
            hasCompletedImageTextIndexing: capturedItem.hasCompletedImageTextIndexing,
            isInHistory: true,
            savedMetadata: savedMetadata,
            source: capturedItem.source
        )
    }

    private mutating func refreshSearchIndex() {
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(text: text, savedMetadata: savedMetadata),
            sourceApplication: self.source.application,
            fileURLs: fileURLs,
            linkURLs: linkURLs,
            imageSearchText: imageSearchText
        )
    }

    private static func searchableText(
        text: String,
        savedMetadata: ClipboardHistorySavedMetadata?
    ) -> String {
        ([text] + [savedMetadata?.title].compactMap { $0 } + (savedMetadata?.tags ?? []))
            .joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case payload
        case capturedAt
        case sourceApplication
        case source
        case lastUsedAt
        case imageSearchText
        case hasCompletedImageTextIndexing
        case isInHistory
        case savedMetadata
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let payload = try container.decode(ClipboardHistoryPayload.self, forKey: .payload)
        payloadReference = ClipboardHistoryPayloadReference(payload: payload)
        let searchableText = payload.searchableText
        text = String(searchableText.prefix(Self.maximumSearchableCharacterCount))
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        source = try container.decodeIfPresent(ClipboardHistorySource.self, forKey: .source)
            ?? ClipboardHistorySource(application: container.decodeIfPresent(
                ClipboardSourceApplication.self, forKey: .sourceApplication
            ))
        kind = payload.kind
        payloadByteCount = payload.byteCount
        filterContentKinds = payload.filterContentKinds
        let completeFileURLs = payload.fileURLs
        fileURLs = payload.metadataFileURLs
        fileReferenceCount = completeFileURLs.count
        linkURLs = payload.metadataLinkURLs
        representationTypeIdentifiers = payload.metadataRepresentationTypeIdentifiers
        hasSinglePlainTextRepresentation = payload.hasSinglePlainTextRepresentation
        imageSearchText = try container.decodeIfPresent(String.self, forKey: .imageSearchText).map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        semanticTraits = ClipboardHistorySemanticClassification.traits(
            text: text,
            linkURLs: payload.metadataLinkURLs,
            imageSearchText: imageSearchText
        )
        payloadDigest = Self.digest(payload)
        allowsRichTextImport = ClipboardRichTextPreviewPolicy.allowsFormattedImport(payload)
        textCharacterCount = searchableText.count
        textLineCount = Self.lineCount(searchableText)
        isSearchTextTruncated = searchableText.count > Self.maximumSearchableCharacterCount
        isInHistory = try container.decodeIfPresent(Bool.self, forKey: .isInHistory) ?? true
        savedMetadata = try container.decodeIfPresent(
            ClipboardHistorySavedMetadata.self,
            forKey: .savedMetadata
        )
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        hasCompletedImageTextIndexing = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedImageTextIndexing
        ) ?? false
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(text: text, savedMetadata: savedMetadata),
            sourceApplication: self.source.application,
            fileURLs: payload.metadataFileURLs,
            linkURLs: payload.metadataLinkURLs,
            imageSearchText: imageSearchText
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(loadPayload(), forKey: .payload)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(sourceApplication, forKey: .sourceApplication)
        try container.encodeIfPresent(source.storageOverride, forKey: .source)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(imageSearchText, forKey: .imageSearchText)
        if !isInHistory {
            try container.encode(false, forKey: .isInHistory)
        }
        try container.encodeIfPresent(savedMetadata, forKey: .savedMetadata)
        if hasCompletedImageTextIndexing {
            try container.encode(true, forKey: .hasCompletedImageTextIndexing)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.capturedAt == rhs.capturedAt
            && lhs.source == rhs.source
            && lhs.kind == rhs.kind
            && lhs.payloadByteCount == rhs.payloadByteCount
            && lhs.filterContentKinds == rhs.filterContentKinds
            && lhs.fileURLs == rhs.fileURLs
            && lhs.fileReferenceCount == rhs.fileReferenceCount
            && lhs.linkURLs == rhs.linkURLs
            && lhs.representationTypeIdentifiers == rhs.representationTypeIdentifiers
            && lhs.hasSinglePlainTextRepresentation == rhs.hasSinglePlainTextRepresentation
            && lhs.semanticTraits == rhs.semanticTraits
            && lhs.payloadDigest == rhs.payloadDigest
            && lhs.allowsRichTextImport == rhs.allowsRichTextImport
            && lhs.textCharacterCount == rhs.textCharacterCount
            && lhs.textLineCount == rhs.textLineCount
            && lhs.isSearchTextTruncated == rhs.isSearchTextTruncated
            && lhs.isInHistory == rhs.isInHistory
            && lhs.savedMetadata == rhs.savedMetadata
            && lhs.lastUsedAt == rhs.lastUsedAt
            && lhs.imageSearchText == rhs.imageSearchText
            && lhs.hasCompletedImageTextIndexing == rhs.hasCompletedImageTextIndexing
    }

    static func digest(_ payload: ClipboardHistoryPayload) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = (try? encoder.encode(payload)) ?? Data()
        return Data(SHA256.hash(data: encoded))
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }
}

enum ClipboardHistoryExpiration: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var interval: TimeInterval? {
        guard self != .never else { return nil }
        return TimeInterval(rawValue * 24 * 60 * 60)
    }
}

struct ClipboardHistorySettings: Equatable, Sendable {
    static let maximumSupportedItemCount = 10_000
    static let defaultMaximumItemCount = 500
    static let defaultMaximumItemByteCount = 30 * 1_024 * 1_024
    static let defaultMaximumTotalPayloadByteCount = 512 * 1_024 * 1_024
    static let maximumSupportedTotalPayloadByteCount = 5 * 1_024 * 1_024 * 1_024

    var isPaused: Bool
    var maximumItemCount: Int
    var expiration: ClipboardHistoryExpiration
    var maximumItemByteCount: Int
    var maximumTotalPayloadByteCount: Int = defaultMaximumTotalPayloadByteCount
    var excludedApplications: [ClipboardExcludedApplication]

    static let defaults = ClipboardHistorySettings(
        isPaused: false,
        maximumItemCount: defaultMaximumItemCount,
        expiration: .thirtyDays,
        maximumItemByteCount: defaultMaximumItemByteCount,
        maximumTotalPayloadByteCount: defaultMaximumTotalPayloadByteCount,
        excludedApplications: [
            ClipboardExcludedApplication(
                bundleIdentifier: "com.apple.Passwords",
                name: "Passwords"
            ),
            ClipboardExcludedApplication(
                bundleIdentifier: "com.apple.keychainaccess",
                name: "Keychain Access"
            ),
            ClipboardExcludedApplication(
                bundleIdentifier: "com.1password.1password",
                name: "1Password"
            ),
            ClipboardExcludedApplication(
                bundleIdentifier: "com.bitwarden.desktop",
                name: "Bitwarden"
            ),
        ]
    )
}

enum ClipboardCaptureIgnoreReason: Equatable, Sendable {
    case paused
    case unsupportedType
    case producerMarkedPrivate
    case excludedApplication
    case empty
    case oversized
    case tooManyObjects
    case historyCapacityFull
    case duplicateNewestItem
}

enum ClipboardCaptureDecision: Equatable, Sendable {
    case capture(ClipboardHistoryItem)
    case ignore(ClipboardCaptureIgnoreReason)
}

enum ClipboardCapturePolicy {
    static let ignoredProducerTypes = ClipboardPasteboardReaderWire.ignoredProducerTypes

    static func preflight(
        types: Set<String>,
        sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings
    ) -> ClipboardCaptureIgnoreReason? {
        if settings.isPaused {
            return .paused
        }
        if !types.isDisjoint(with: ignoredProducerTypes) {
            return .producerMarkedPrivate
        }
        guard types.contains(where: ClipboardRepresentationType.isSupported) else {
            return .unsupportedType
        }
        if let bundleIdentifier = sourceApplication?.bundleIdentifier,
           settings.excludedApplications.contains(where: {
               $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
           }) {
            return .excludedApplication
        }
        return nil
    }

    static func evaluatePayload(
        _ payload: ClipboardHistoryPayload?,
        sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings,
        newestItem: ClipboardHistoryItem?,
        now: Date = Date(),
        makeID: () -> UUID = UUID.init,
        source: ClipboardHistorySource? = nil
    ) -> ClipboardCaptureDecision {
        guard let payload, !payload.pasteboardItems.isEmpty else {
            return .ignore(.empty)
        }
        guard payload.byteCount <= settings.maximumItemByteCount else {
            return .ignore(.oversized)
        }

        let text = payload.searchableText
        if payload.kind == .plainText {
            guard !normalizedText(text).isEmpty else {
                return .ignore(.empty)
            }
        }
        let payloadDigest = ClipboardHistoryItem.digest(payload)
        if let newestItem,
           payloadsAreDuplicates(payload, payloadDigest: payloadDigest, newestItem) {
            return .ignore(.duplicateNewestItem)
        }
        return .capture(ClipboardHistoryItem(
            id: makeID(),
            payload: payload,
            capturedAt: now,
            sourceApplication: sourceApplication,
            isPinned: false,
            lastUsedAt: nil,
            precomputedPayloadDigest: payloadDigest,
            source: source
        ))
    }

    static func evaluateText(
        _ text: String?,
        sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings,
        newestItem: ClipboardHistoryItem?,
        now: Date = Date(),
        makeID: () -> UUID = UUID.init
    ) -> ClipboardCaptureDecision {
        guard let text else { return .ignore(.empty) }
        return evaluatePayload(
            .plainText(text),
            sourceApplication: sourceApplication,
            settings: settings,
            newestItem: newestItem,
            now: now,
            makeID: makeID
        )
    }

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func payloadsAreDuplicates(
        _ lhs: ClipboardHistoryPayload,
        payloadDigest: Data,
        _ rhs: ClipboardHistoryItem
    ) -> Bool {
        if lhs.kind == .plainText,
           rhs.kind == .plainText,
           !lhs.plainTexts.isEmpty,
           !rhs.text.isEmpty {
            let rhsText: String
            if rhs.isSearchTextTruncated,
               let rhsPayload = try? rhs.loadPayload() {
                defer { rhs.discardCachedPayloadIfReloadable() }
                rhsText = rhsPayload.searchableText
            } else {
                rhsText = rhs.text
            }
            return normalizedText(lhs.searchableText) == normalizedText(rhsText)
        }
        return payloadDigest == rhs.payloadDigest
    }
}

struct ClipboardHistoryUsage: Equatable, Sendable {
    let itemCount: Int
    let payloadByteCount: Int

    init(items: [ClipboardHistoryItem]) {
        itemCount = items.count
        payloadByteCount = items.reduce(0) { $0 + $1.payloadByteCount }
    }
}

struct ClipboardRetentionResult: Equatable, Sendable {
    let items: [ClipboardHistoryItem]
    let evictedItemCount: Int
    let isCaptureBlockedByProtectedItems: Bool
}

enum ClipboardRetentionPolicy {
    // Legacy single-file storage ceiling, independent of the configurable history capacity.
    static let maximumTotalPayloadByteCount = 64 * 1_024 * 1_024

    static func prune(
        _ items: [ClipboardHistoryItem],
        settings: ClipboardHistorySettings,
        now: Date = Date(),
        protectedItemIDs: Set<UUID> = [],
        shortcutRetainedItemIDs: Set<UUID> = []
    ) -> [ClipboardHistoryItem] {
        evaluate(
            items,
            settings: settings,
            now: now,
            protectedItemIDs: protectedItemIDs,
            shortcutRetainedItemIDs: shortcutRetainedItemIDs
        ).items
    }

    static func evaluate(
        _ items: [ClipboardHistoryItem],
        settings: ClipboardHistorySettings,
        now: Date = Date(),
        protectedItemIDs: Set<UUID> = [],
        shortcutRetainedItemIDs: Set<UUID> = []
    ) -> ClipboardRetentionResult {
        let historyItems = items.filter(\.isInHistory)
        let newestFirstItems: [ClipboardHistoryItem]
        if zip(historyItems, historyItems.dropFirst()).allSatisfy({ pair in
            pair.0.capturedAt >= pair.1.capturedAt
        }) {
            newestFirstItems = historyItems
        } else {
            newestFirstItems = historyItems.sorted(by: newestFirst)
        }
        let unexpired: [ClipboardHistoryItem]
        if let interval = settings.expiration.interval {
            let cutoff = now.addingTimeInterval(-interval)
            unexpired = newestFirstItems.filter {
                protectedItemIDs.contains($0.id)
                    || shortcutRetainedItemIDs.contains($0.id)
                    || $0.lastActivityAt >= cutoff
            }
        } else {
            unexpired = newestFirstItems
        }
        let queueProtected = unexpired.filter {
            protectedItemIDs.contains($0.id)
        }
        // Shortcut-retained History remains available until its timer ends, but it does not
        // consume the ordinary History count or payload budget used for new captures.
        let shortcutRetained = unexpired.filter {
            !protectedItemIDs.contains($0.id) && shortcutRetainedItemIDs.contains($0.id)
        }
        let recent = unexpired.filter {
            !protectedItemIDs.contains($0.id) && !shortcutRetainedItemIDs.contains($0.id)
        }
        let maximumItemCount = max(0, settings.maximumItemCount)

        // Active sequential queues protect their immutable snapshot until completion or
        // cancellation. Shortcut-retained items are exempt from ordinary History retention.
        var retained = queueProtected + shortcutRetained
        let protectedItemCount = queueProtected.count
        let protectedPayloadBytes = queueProtected.reduce(0) { $0 + $1.payloadByteCount }
        var retainedPayloadBytes = protectedPayloadBytes
        let availableRecentCount = max(0, maximumItemCount - queueProtected.count)
        var retainedRecentCount = 0
        for item in recent {
            if retainedRecentCount >= availableRecentCount {
                break
            }
            let byteCount = item.payloadByteCount
            guard retainedPayloadBytes + byteCount <= settings.maximumTotalPayloadByteCount else {
                continue
            }
            retained.append(item)
            retainedPayloadBytes += byteCount
            retainedRecentCount += 1
        }
        let retainedIDs = Set(retained.map(\.id))
        let unifiedItems = items.compactMap { item -> ClipboardHistoryItem? in
            if retainedIDs.contains(item.id) {
                var retainedItem = item
                retainedItem.setHistoryMembership(true)
                return retainedItem
            }
            guard item.isSaved else { return nil }
            var savedOnlyItem = item
            savedOnlyItem.setHistoryMembership(false)
            return savedOnlyItem
        }.sorted(by: unifiedOrder)
        let evictedItemCount = historyItems.lazy.filter { !retainedIDs.contains($0.id) }.count
        return ClipboardRetentionResult(
            items: unifiedItems,
            evictedItemCount: evictedItemCount,
            isCaptureBlockedByProtectedItems:
                protectedItemCount >= maximumItemCount
                || protectedPayloadBytes >= settings.maximumTotalPayloadByteCount
        )
    }

    private static func newestFirst(_ lhs: ClipboardHistoryItem, _ rhs: ClipboardHistoryItem) -> Bool {
        lhs.capturedAt > rhs.capturedAt
    }

    private static func unifiedOrder(
        _ lhs: ClipboardHistoryItem,
        _ rhs: ClipboardHistoryItem
    ) -> Bool {
        if lhs.isInHistory != rhs.isInHistory { return lhs.isInHistory }
        if lhs.isInHistory {
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt > rhs.capturedAt }
        } else {
            let lhsActivity = lhs.savedActivityAt ?? lhs.capturedAt
            let rhsActivity = rhs.savedActivityAt ?? rhs.capturedAt
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum ClipboardHistorySearch {
    static let maximumNormalizedCharacterCount = 4_096
    static let maximumTokenCount = 128
    static let maximumTokenCharacterCount = 128
    static let maximumPrimaryTextTokenCount = 48
    static let maximumWordFragmentStateCount = 512

    struct Result: Equatable, Sendable {
        let items: [ClipboardHistoryItem]
        let hasMore: Bool
    }

    struct PreparedQuery: Sendable {
        let normalizedText: String
        let tokens: [String]
        let compactCharacters: [Character]
        let distinctCharacters: Set<Character>
        let allowsSubstring: Bool
        let isEmpty: Bool

        init(_ query: String) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            isEmpty = trimmed.isEmpty
            normalizedText = String(ClipboardHistorySearch.normalized(
                String(trimmed.prefix(maximumNormalizedCharacterCount))
            ).prefix(maximumNormalizedCharacterCount))
            tokens = ClipboardHistorySearch.tokens(in: normalizedText)
            let compact = ClipboardHistorySearch.compactTokens(tokens)
            compactCharacters = Array(compact)
            distinctCharacters = Set(compactCharacters)
            allowsSubstring = ClipboardHistorySearch.allowsExactSubstringMatch(
                normalizedText, compactQuery: compact
            )
        }
    }

    private struct WordFragmentSearchState: Hashable {
        let queryOffset: Int
        let wordIndex: Int
        let minimumFragmentLength: Int
        let usedWordCount: Int
    }

    static func filter(_ items: [ClipboardHistoryItem], query: String) -> [ClipboardHistoryItem] {
        result(items, query: query, limit: nil).items
    }

    static func matches(text: String, query: String) -> Bool {
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: .distantPast,
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        return !result([item], query: query, limit: 1).items.isEmpty
    }

    static func matches(index: ClipboardHistorySearchIndex, query: String) -> Bool {
        matches(index: index, query: PreparedQuery(query))
    }

    static func matches(index: ClipboardHistorySearchIndex, query: PreparedQuery) -> Bool {
        guard !query.isEmpty else { return true }
        if query.allowsSubstring, index.normalizedText.contains(query.normalizedText) {
            return true
        }
        if !query.tokens.isEmpty,
           query.tokens.allSatisfy({ queryToken in
               index.tokens.contains { $0.hasPrefix(queryToken) }
           }) {
            return true
        }
        return compactQueryMatchesWordFragments(query, words: index.tokens)
    }

    static func result(
        _ items: [ClipboardHistoryItem],
        query: String,
        limit: Int?
    ) -> Result {
        let preparedQuery = PreparedQuery(query)
        guard !preparedQuery.isEmpty else {
            guard let limit, items.count > limit else {
                return Result(items: items, hasMore: false)
            }
            return Result(items: Array(items.prefix(limit)), hasMore: true)
        }
        var matches: [ClipboardHistoryItem] = []
        for item in items {
            guard !Task.isCancelled else { return Result(items: [], hasMore: false) }
            if Self.matches(index: item.searchIndex, query: preparedQuery) {
                matches.append(item)
            }
            if let limit, matches.count > limit {
                return Result(items: Array(matches.prefix(limit)), hasMore: true)
            }
        }
        return Result(items: matches, hasMore: false)
    }

    static func makeIndex(
        text: String,
        sourceApplication: ClipboardSourceApplication?,
        fileURLs: [URL],
        linkURLs: [URL] = [],
        imageSearchText: String?
    ) -> ClipboardHistorySearchIndex {
        let fields: [(value: String?, characterLimit: Int, tokenLimit: Int)] = [
            (text, 2_048, maximumPrimaryTextTokenCount),
            (sourceApplication?.name, 256, 16),
            (sourceApplication?.bundleIdentifier, 256, 16),
            (fileURLs.map(\.path).joined(separator: " "), 508, 16),
            (linkURLs.map(\.absoluteString).joined(separator: " "), 508, 16),
            (imageSearchText, ClipboardHistoryItem.maximumSearchableCharacterCount, 64),
        ]
        let boundedFields = fields.compactMap { field -> (value: String, tokenLimit: Int)? in
            guard let value = field.value, !value.isEmpty else { return nil }
            let normalizedValue = normalized(String(value.prefix(field.characterLimit)))
            guard !normalizedValue.isEmpty else { return nil }
            return (
                String(normalizedValue.prefix(field.characterLimit)),
                field.tokenLimit
            )
        }
        let normalizedText = String(
            boundedFields.map(\.value).joined(separator: " ").prefix(maximumNormalizedCharacterCount)
        )
        let indexedTokens = boundedFields.flatMap { field in
            tokens(in: field.value, maximumCount: field.tokenLimit)
        }
        return ClipboardHistorySearchIndex(
            normalizedText: normalizedText,
            tokens: Array(indexedTokens.prefix(maximumTokenCount))
        )
    }

    private static func compactTokens(_ tokens: [String]) -> String {
        tokens.joined()
    }

    private static func allowsExactSubstringMatch(
        _ query: String,
        compactQuery: String
    ) -> Bool {
        if compactQuery.count >= 2 {
            return true
        }
        return query.unicodeScalars.contains { !$0.isASCII }
    }

    private static func compactQueryMatchesWordFragments(
        _ query: PreparedQuery,
        words: [String]
    ) -> Bool {
        let queryCharacters = query.compactCharacters
        guard queryCharacters.count >= 2, words.count >= 2 else { return false }
        // Every fragment must come from an indexed word. Reject impossible queries
        // before allocating character arrays or exploring repeated-token states.
        guard query.distinctCharacters.allSatisfy({ character in
            words.contains { $0.contains(character) }
        }) else { return false }
        let wordCharacters = words.map(Array.init)
        var memoizedResults: [WordFragmentSearchState: Bool] = [:]

        func commonPrefixLength(queryOffset: Int, word: [Character], wordOffset: Int = 0) -> Int {
            let limit = min(queryCharacters.count - queryOffset, word.count - wordOffset)
            var length = 0
            while length < limit,
                  queryCharacters[queryOffset + length] == word[wordOffset + length] {
                length += 1
            }
            return length
        }

        // An interior first fragment is always a prefix of the compact query.
        // Calculate its longest occurrence once per needed word, not once per
        // length, and do no interior work when ordinary prefixes already match.
        var interiorPrefixLengths = Array(repeating: -1, count: wordCharacters.count)
        func interiorPrefixLength(at wordIndex: Int) -> Int {
            if interiorPrefixLengths[wordIndex] >= 0 { return interiorPrefixLengths[wordIndex] }
            let word = wordCharacters[wordIndex]
            let length = word.indices.reduce(0) { longest, offset in
                max(longest, commonPrefixLength(queryOffset: 0, word: word, wordOffset: offset))
            }
            interiorPrefixLengths[wordIndex] = length
            return length
        }

        func matches(
            queryOffset: Int,
            wordIndex: Int,
            minimumFragmentLength: Int,
            usedWordCount: Int
        ) -> Bool {
            guard !Task.isCancelled else { return false }
            if queryOffset == queryCharacters.count {
                return usedWordCount >= 2
            }
            guard wordIndex < wordCharacters.count else { return false }
            let state = WordFragmentSearchState(
                queryOffset: queryOffset,
                wordIndex: wordIndex,
                minimumFragmentLength: minimumFragmentLength,
                usedWordCount: min(usedWordCount, 2)
            )
            if let memoizedResult = memoizedResults[state] {
                return memoizedResult
            }
            guard memoizedResults.count < maximumWordFragmentStateCount else {
                return false
            }
            let word = wordCharacters[wordIndex]
            let remainingCount = queryCharacters.count - queryOffset
            let maximumPrefixLength = min(word.count, remainingCount)
            guard maximumPrefixLength >= minimumFragmentLength else {
                memoizedResults[state] = false
                return false
            }

            let matchingPrefixLength = commonPrefixLength(queryOffset: queryOffset, word: word)
            if matchingPrefixLength >= minimumFragmentLength {
                for prefixLength in minimumFragmentLength...matchingPrefixLength {
                    if matchesWordFragment(
                        length: prefixLength,
                        queryOffset: queryOffset,
                        wordIndex: wordIndex,
                        usedWordCount: usedWordCount
                    ) {
                        memoizedResults[state] = true
                        return true
                    }
                }
            }

            if usedWordCount == 0 {
                let maximumInteriorLength = interiorPrefixLength(at: wordIndex)
                if maximumInteriorLength >= 2 {
                    for fragmentLength in 2...maximumInteriorLength {
                        if matchesWordFragment(
                            length: fragmentLength,
                            queryOffset: queryOffset,
                            wordIndex: wordIndex,
                            usedWordCount: usedWordCount
                        ) {
                            memoizedResults[state] = true
                            return true
                        }
                    }
                }
            }
            memoizedResults[state] = false
            return false
        }

        func matchesWordFragment(
            length: Int,
            queryOffset: Int,
            wordIndex: Int,
            usedWordCount: Int
        ) -> Bool {
            let nextQueryOffset = queryOffset + length
            if nextQueryOffset == queryCharacters.count {
                return usedWordCount + 1 >= 2
            }
            for nextWordIndex in (wordIndex + 1)..<wordCharacters.count {
                if matches(
                    queryOffset: nextQueryOffset,
                    wordIndex: nextWordIndex,
                    minimumFragmentLength: nextWordIndex == wordIndex + 1 ? 1 : 3,
                    usedWordCount: usedWordCount + 1
                ) {
                    return true
                }
            }
            return false
        }

        for startIndex in wordCharacters.indices {
            if matches(
                queryOffset: 0,
                wordIndex: startIndex,
                minimumFragmentLength: 1,
                usedWordCount: 0
            ) {
                return true
            }
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        return folded.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func tokens(
        in value: String,
        maximumCount: Int = maximumTokenCount
    ) -> [String] {
        Array(value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(maximumCount))
            .map { String($0.prefix(maximumTokenCharacterCount)) }
    }
}
