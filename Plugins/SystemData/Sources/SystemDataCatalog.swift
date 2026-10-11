import Foundation

/// How a catalog item is measured.
public enum SystemDataItemKind: Equatable, Sendable {
    /// Measure the path itself. `excluding` names are skipped at the root level
    /// so a location claimed by another item is never counted twice.
    case path(excluding: Set<String> = [])
    /// Measure every direct subdirectory of the path as its own item and fold
    /// the parent's own files into a synthetic "other files" entry.
    case children(excluding: Set<String> = [])
}

/// Optional pre-measurement path resolution for items whose location is
/// configured by an external tool instead of a fixed convention.
public enum SystemDataPathResolver: Equatable, Sendable {
    /// Prefer the first line of `<executable> <arguments>` output (for example
    /// `go env GOMODCACHE` or `uv cache dir`); fall back to the static `path`
    /// template when the tool is missing or reports nothing usable.
    case toolOutput(executable: String, arguments: [String])
}

public struct SystemDataItemDefinition: Equatable, Sendable {
    public let id: String
    public let label: SystemDataLabel
    /// Path template; a leading `~` expands to the current home directory.
    public let path: String
    public let badge: SystemDataBadge
    public let kind: SystemDataItemKind
    /// When set, the scanner resolves a dynamic location before measuring.
    public let pathResolver: SystemDataPathResolver?

    public init(
        id: String,
        label: SystemDataLabel,
        path: String,
        badge: SystemDataBadge,
        kind: SystemDataItemKind,
        pathResolver: SystemDataPathResolver? = nil
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.badge = badge
        self.kind = kind
        self.pathResolver = pathResolver
    }
}

public struct SystemDataGroupDefinition: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: SystemDataLabel
    public let systemImage: String
    public let items: [SystemDataItemDefinition]

    public init(
        id: String,
        label: SystemDataLabel,
        systemImage: String,
        items: [SystemDataItemDefinition]
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.items = items
    }
}

/// The fixed set of locations this plugin measures: caches, logs, temporary
/// data, developer artifacts, package-manager stores, models, containers,
/// backups, application data, instant-message chats, and the readable parts
/// of the system volume.
///
/// Personal data (Mail, Messages, photos, Desktop, Documents) is deliberately
/// out of scope, and protected locations such as app containers report as
/// unreadable until the user grants Full Disk Access from the settings
/// permission card instead of the plugin prompting for it.
public enum SystemDataCatalog {
    public static let groups: [SystemDataGroupDefinition] = [
        SystemDataGroupDefinition(
            id: "logs",
            label: .localized(key: "group.logs", fallback: "日志与诊断"),
            systemImage: "doc.text",
            items: [
                SystemDataItemDefinition(
                    id: "logs.user",
                    label: .localized(key: "item.logs.user", fallback: "用户日志"),
                    path: "~/Library/Logs",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "logs.system",
                    label: .localized(key: "item.logs.system", fallback: "系统与应用日志"),
                    path: "/Library/Logs",
                    badge: .safe,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "xcode",
            label: .localized(key: "group.xcode", fallback: "Xcode 与模拟器"),
            systemImage: "hammer",
            items: [
                SystemDataItemDefinition(
                    id: "xcode.derived-data",
                    label: .localized(key: "item.xcode.derivedData", fallback: "DerivedData"),
                    path: "~/Library/Developer/Xcode/DerivedData",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "xcode.archives",
                    label: .localized(key: "item.xcode.archives", fallback: "归档"),
                    path: "~/Library/Developer/Xcode/Archives",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "xcode.device-support",
                    label: .localized(key: "item.xcode.deviceSupport", fallback: "设备调试符号"),
                    path: "~/Library/Developer/Xcode/iOS DeviceSupport",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "xcode.simulator-devices",
                    label: .localized(key: "item.xcode.simulatorDevices", fallback: "模拟器设备"),
                    path: "~/Library/Developer/CoreSimulator/Devices",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "xcode.simulator-caches",
                    label: .localized(key: "item.xcode.simulatorCaches", fallback: "模拟器缓存"),
                    path: "~/Library/Developer/CoreSimulator/Caches",
                    badge: .safe,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "developer",
            label: .localized(key: "group.developer", fallback: "开发工具数据"),
            systemImage: "chevron.left.forwardslash.chevron.right",
            items: [
                SystemDataItemDefinition(
                    id: "developer.gomod",
                    label: .localized(key: "item.developer.gomod", fallback: "Go 模块"),
                    path: "~/go/pkg/mod",
                    badge: .review,
                    kind: .path(),
                    pathResolver: .toolOutput(executable: "go", arguments: ["env", "GOMODCACHE"])
                ),
                SystemDataItemDefinition(
                    id: "developer.maven",
                    label: .localized(key: "item.developer.maven", fallback: "Maven 仓库"),
                    path: "~/.m2/repository",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "developer.gradle",
                    label: .localized(key: "item.developer.gradle", fallback: "Gradle 缓存"),
                    path: "~/.gradle/caches",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "developer.rustup",
                    label: .literal("rustup"),
                    path: "~/.rustup",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "developer.nvm",
                    label: .literal("nvm"),
                    path: "~/.nvm",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "developer.uvcache",
                    label: .localized(key: "item.developer.uvcache", fallback: "UV 缓存"),
                    path: "~/.cache/uv",
                    badge: .review,
                    kind: .path(),
                    pathResolver: .toolOutput(executable: "uv", arguments: ["cache", "dir"])
                ),
                SystemDataItemDefinition(
                    id: "packages.homebrew",
                    label: .localized(key: "item.packages.homebrew", fallback: "Homebrew"),
                    path: "~/Library/Caches/Homebrew",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "packages.npm",
                    label: .literal("npm"),
                    path: "~/.npm/_cacache",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "packages.yarn",
                    label: .literal("Yarn"),
                    path: "~/Library/Caches/Yarn",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "packages.pnpm",
                    label: .literal("pnpm"),
                    path: "~/Library/Caches/pnpm",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "packages.pip",
                    label: .literal("pip"),
                    path: "~/Library/Caches/pip",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "packages.cocoapods",
                    label: .literal("CocoaPods"),
                    path: "~/Library/Caches/CocoaPods",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "packages.cargo",
                    label: .literal("Cargo"),
                    path: "~/.cargo/registry",
                    badge: .review,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "ai",
            label: .localized(key: "group.ai", fallback: "AI 模型"),
            systemImage: "sparkles",
            items: [
                SystemDataItemDefinition(
                    id: "ai.ollama",
                    label: .literal("Ollama"),
                    path: "~/.ollama/models",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "ai.huggingface",
                    label: .literal("Hugging Face"),
                    path: "~/.cache/huggingface",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "ai.lmstudio",
                    label: .literal("LM Studio"),
                    path: "~/.lmstudio/models",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "ai.omlx",
                    label: .literal("oMLX"),
                    path: "~/.omlx",
                    badge: .review,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "docker",
            label: .localized(key: "group.docker", fallback: "容器与虚拟机"),
            systemImage: "cube",
            items: [
                SystemDataItemDefinition(
                    id: "docker.desktop",
                    label: .literal("Docker Desktop"),
                    path: "~/Library/Containers/com.docker.docker/Data/vms",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "docker.orbstack",
                    label: .literal("OrbStack"),
                    path: "~/.orbstack",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "docker.applecontainer",
                    label: .literal("Apple Container"),
                    path: "~/Library/Application Support/com.apple.container",
                    badge: .review,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "backups",
            label: .localized(key: "group.backups", fallback: "iOS 设备备份"),
            systemImage: "iphone",
            items: [
                SystemDataItemDefinition(
                    id: "backups.mobilesync",
                    label: .localized(key: "item.backups.mobilesync", fallback: "设备备份"),
                    path: "~/Library/Application Support/MobileSync/Backup",
                    badge: .review,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "appdata",
            label: .localized(key: "group.appdata", fallback: "应用数据"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "appdata.root",
                    label: .localized(key: "group.appdata", fallback: "应用数据"),
                    path: "~/Library/Application Support",
                    badge: .review,
                    // Claimed by other items so each path is counted once:
                    // MobileSync by the backups group, the Apple container by
                    // the containers group.
                    kind: .children(excluding: ["MobileSync", "com.apple.container"])
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "im",
            label: .localized(key: "group.im", fallback: "IM 聊天工具"),
            systemImage: "bubble.left.and.bubble.right",
            items: [
                SystemDataItemDefinition(
                    id: "im.wechat",
                    label: .localized(key: "item.im.wechat", fallback: "微信"),
                    path: "~/Library/Containers/com.tencent.xinWeChat",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "im.qq",
                    label: .localized(key: "item.im.qq", fallback: "QQ"),
                    path: "~/Library/Containers/com.tencent.qq",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "im.wecom",
                    label: .localized(key: "item.im.wecom", fallback: "企业微信"),
                    path: "~/Library/Containers/com.tencent.WeWorkMac",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "im.zhenglianxun",
                    label: .localized(key: "item.im.zhenglianxun", fallback: "证联讯"),
                    path: "~/Library/Containers/com.tencent.WxWorkMacEntCustomized",
                    badge: .review,
                    kind: .path()
                ),
            ]
        ),
        SystemDataGroupDefinition(
            id: "system",
            label: .localized(key: "group.system", fallback: "系统"),
            systemImage: "gearshape",
            items: [
                SystemDataItemDefinition(
                    id: "system.library-caches",
                    label: .localized(key: "item.system.libraryCaches", fallback: "系统应用缓存"),
                    path: "/Library/Caches",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "system.var-log",
                    label: .localized(key: "item.system.varLog", fallback: "系统日志"),
                    path: "/private/var/log",
                    badge: .safe,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "system.command-line-tools",
                    label: .localized(key: "item.system.commandLineTools", fallback: "命令行工具"),
                    path: "/Library/Developer/CommandLineTools",
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "trash.home",
                    label: .localized(key: "item.trash.home", fallback: "废纸篓"),
                    path: "~/.Trash",
                    // Trash contents may not be recoverable once removed.
                    badge: .review,
                    kind: .path()
                ),
                SystemDataItemDefinition(
                    id: "caches.user",
                    label: .localized(key: "item.caches.user", fallback: "用户缓存"),
                    path: "~/Library/Caches",
                    // Claimed by the package-manager items so each cache is counted once.
                    badge: .safe,
                    kind: .path(excluding: ["Homebrew", "Yarn", "pnpm", "pip", "CocoaPods"])
                ),
                SystemDataItemDefinition(
                    id: "temporary.varfolders",
                    label: .localized(key: "item.temporary.varfolders", fallback: "系统临时目录"),
                    path: "/private/var/folders",
                    badge: .safe,
                    kind: .path()
                ),
            ]
        ),
    ]

    /// Expands a leading `~` (or a whole `~`) to `home`. Non-`~` paths return
    /// unchanged; callers rely on this to keep absolute paths verbatim.
    public static func expand(path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        guard path == "~" else { return home + "/" + path.dropFirst(2) }
        return home
    }
}
