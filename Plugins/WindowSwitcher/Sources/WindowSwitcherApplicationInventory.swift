import AppKit

/// A captured PID distributes keys without depending on NSRunningApplication's
/// hash. Object equality still distinguishes process lifetimes and accepts new
/// wrappers for the same running application.
struct WindowSwitcherApplicationIdentity: Hashable {
    let processIdentifier: pid_t
    let application: NSObject

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier && lhs.application.isEqual(rhs.application)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(processIdentifier)
    }
}

/// Keeps LaunchServices reads out of ordinary window refreshes. Application
/// equality and an explicit lifetime distinguish replacements that reuse a PID.
@MainActor
final class WindowSwitcherApplicationInventory {
    typealias Application = WindowSwitcherAppCatalog.Application

    struct Source {
        var identity: AnyHashable
        var load: () -> Application?
        var observe: (@escaping @MainActor @Sendable () -> Void) -> [NSKeyValueObservation] = { _ in [] }
    }

    private struct Entry {
        var source: Source
        var application: Application
        var observations: [NSKeyValueObservation]
        let observationID = UUID()
    }

    var onChange: ((Set<pid_t>) -> Void)?
    private let sourceProvider: () -> [Source]
    private let workspace: NSWorkspace?
    private var observation: NSKeyValueObservation?
    private var entries: [AnyHashable: Entry] = [:]
    private var running = false
    private var generation = UUID()

    init(sourceProvider: (() -> [Source])? = nil) {
        workspace = sourceProvider == nil ? .shared : nil
        self.sourceProvider = sourceProvider ?? {
            NSWorkspace.shared.runningApplications.map(Self.source)
        }
    }

    var applications: [Application] { entries.values.map(\.application) }

    func start() {
        guard !running else { return }
        running = true
        let generation = generation
        observation = workspace?.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                reconcile()
            }
        }
        reconcile(notify: false)
    }

    func stop() {
        running = false
        generation = UUID()
        observation = nil
        entries.removeAll()
    }

    /// Also called on invocation and coarse reconciliation to recover a missed
    /// process-list notification without rereading every application's properties.
    func reconcile(notify: Bool = true) {
        guard running else { return }
        let sources = sourceProvider()
        let live = Set(sources.map(\.identity))
        var changed = Set<pid_t>()
        for identity in Array(entries.keys) where !live.contains(identity) {
            if let removed = entries.removeValue(forKey: identity) {
                changed.insert(removed.application.processIdentifier)
            }
        }
        for source in sources where entries[source.identity] == nil {
            guard var application = source.load(), application.processIdentifier > 0 else { continue }
            application.lifetime = UUID()
            let identity = source.identity
            let generation = generation
            entries[identity] = Entry(source: source, application: application, observations: [])
            let observationID = entries[identity]?.observationID
            entries[identity]?.observations = source.observe { [weak self] in
                guard let self, self.generation == generation,
                      self.entries[identity]?.observationID == observationID else { return }
                reload(identity)
            }
            changed.insert(application.processIdentifier)
        }
        if notify, !changed.isEmpty { onChange?(changed) }
    }

    func reload(processIdentifier: pid_t) {
        for identity in entries.keys where entries[identity]?.application.processIdentifier == processIdentifier {
            reload(identity)
            break
        }
    }

    private func reload(_ identity: AnyHashable) {
        guard running, var entry = entries[identity] else { return }
        let old = entry.application
        guard var application = entry.source.load(), application.processIdentifier > 0 else {
            entries.removeValue(forKey: identity)
            onChange?([old.processIdentifier])
            return
        }
        application.lifetime = application.processIdentifier == old.processIdentifier
            ? old.lifetime : UUID()
        entry.application = application
        entries[identity] = entry
        onChange?([old.processIdentifier, application.processIdentifier])
    }

    private static func source(_ app: NSRunningApplication) -> Source {
        let presentation = Presentation(application: app)
        let identity = WindowSwitcherApplicationIdentity(processIdentifier: app.processIdentifier, application: app)
        return Source(identity: AnyHashable(identity), load: { presentation.snapshot() }, observe: { changed in
            let handler: @Sendable (NSRunningApplication, NSKeyValueObservedChange<Bool>) -> Void = { _, _ in
                Task { @MainActor in changed() }
            }
            return [
                app.observe(\.isTerminated, changeHandler: handler),
                app.observe(\.isHidden, changeHandler: handler),
                app.observe(\.isActive, changeHandler: handler),
                app.observe(\.activationPolicy) { _, _ in
                    Task { @MainActor in presentation.invalidateMetadata(); changed() }
                },
                app.observe(\.isFinishedLaunching) { _, _ in
                    Task { @MainActor in presentation.invalidateMetadata(); changed() }
                },
                app.observe(\.processIdentifier) { _, _ in Task { @MainActor in changed() } }
            ]
        })
    }

    @MainActor
    private final class Presentation {
        private struct Metadata {
            let pid: pid_t
            let bundleIdentifier: String?
            let bundlePath: String?
            let launchDate: Date?
        }

        let application: NSRunningApplication
        private var metadata: Metadata?
        private var loaded = false
        private var name: String?
        private var icon: NSImage?

        init(application: NSRunningApplication) { self.application = application }

        func invalidateMetadata() {
            metadata = nil
            loaded = false
            name = nil
            icon = nil
        }

        func snapshot() -> Application? {
            guard !application.isTerminated else { return nil }
            let pid = application.processIdentifier
            if metadata?.pid != pid {
                invalidateMetadata()
                metadata = Metadata(pid: pid, bundleIdentifier: application.bundleIdentifier,
                                    bundlePath: application.bundleURL?.path, launchDate: application.launchDate)
            }
            guard let metadata else { return nil }
            let hidden = application.isHidden
            let active = application.isActive
            return Application(processIdentifier: pid, bundleIdentifier: metadata.bundleIdentifier,
                bundlePath: metadata.bundlePath, localizedName: nil, launchDate: metadata.launchDate,
                isRegular: application.activationPolicy == .regular, isHidden: hidden, isActive: active,
                loadPresentation: { self.value(isHidden: hidden, isActive: active) })
        }

        func value(isHidden: Bool, isActive: Bool) -> Application.Presentation {
            if !loaded {
                name = application.localizedName
                icon = application.icon
                loaded = true
            }
            return .init(localizedName: name, icon: icon, isHidden: isHidden, isActive: isActive)
        }
    }
}
