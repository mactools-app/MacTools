import AppKit
import Foundation

/// Terminals the plugin can hand an interactive container shell to. Only the
/// system default and installed applications are offered in settings, so a
/// missing app never becomes a dead choice.
public enum ContainerTerminalApplication: String, CaseIterable, Equatable, Sendable {
    case systemDefault
    case terminal
    case iterm
    case ghostty
    case wezterm
    case kitty
    case alacritty

    public var bundleIdentifier: String? {
        switch self {
        case .systemDefault:
            return nil
        case .terminal:
            return "com.apple.Terminal"
        case .iterm:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .wezterm:
            return "com.github.wez.wezterm"
        case .kitty:
            return "net.kovidgoyal.kitty"
        case .alacritty:
            return "org.alacritty"
        }
    }

    /// Stable settings option identifier: the raw value.
    public var optionID: String { rawValue }

    /// Brand names stay untranslated; only the system default needs copy.
    public var localizationKey: String {
        switch self {
        case .systemDefault:
            return "settings.terminal.application.systemDefault"
        default:
            return "settings.terminal.application.\(rawValue)"
        }
    }

    public var defaultTitle: String {
        switch self {
        case .systemDefault:
            return "系统默认"
        case .terminal:
            return "终端"
        case .iterm:
            return "iTerm"
        case .ghostty:
            return "Ghostty"
        case .wezterm:
            return "WezTerm"
        case .kitty:
            return "kitty"
        case .alacritty:
            return "Alacritty"
        }
    }

    /// Maps a resolved application bundle back to a supported terminal.
    public init?(applicationURL: URL) {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier,
              let match = Self.allCases.first(where: {
                  $0.bundleIdentifier == bundleIdentifier
              })
        else {
            return nil
        }
        self = match
    }
}

/// Resolves the selected terminal to a concrete application bundle.
@MainActor
public enum ContainerTerminalApplicationCatalog {
    public static func applicationURL(
        for application: ContainerTerminalApplication,
        workspace: NSWorkspace = .shared
    ) -> URL? {
        guard let bundleIdentifier = application.bundleIdentifier else { return nil }
        return workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// The picker keeps the system default first and then every terminal that
    /// is actually installed, so the list matches what the launcher can use.
    public static func installedApplications(
        workspace: NSWorkspace = .shared
    ) -> [ContainerTerminalApplication] {
        ContainerTerminalApplication.allCases.filter { application in
            application == .systemDefault
                || applicationURL(for: application, workspace: workspace) != nil
        }
    }
}
