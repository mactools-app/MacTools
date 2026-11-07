struct QuitProtectionRule: Codable, Equatable {
    enum AppScope: String, Codable, CaseIterable {
        case all
        case selected
        case allExcept
    }

    enum Modifier: String, Codable {
        case option
        case control
        case shift
    }

    enum Confirmation: Codable, Equatable {
        case hold(Duration)
        case doublePress(Duration)
        case extraModifier(Modifier?)
    }

    var isEnabled = false
    var scope: AppScope = .selected
    var selectedApps: Set<String> = []
    var excludedApps: Set<String> = []
    var confirmation: Confirmation = .hold(.milliseconds(800))

    func includes(bundleIdentifier: String?) -> Bool {
        guard isEnabled, let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }

        switch scope {
        case .all:
            return true
        case .selected:
            return selectedApps.contains(bundleIdentifier)
        case .allExcept:
            return !excludedApps.contains(bundleIdentifier)
        }
    }

    func intent<Target: Equatable>(
        for target: Target,
        additionalModifier: Modifier?,
        verifiedExtraModifier: Modifier?
    ) -> QuitProtectionGesture<Target>.Intent? {
        switch confirmation {
        case let .hold(duration) where additionalModifier == nil:
            return .hold(target, duration: duration)
        case let .doublePress(interval) where additionalModifier == nil:
            return .doublePress(target, interval: interval)
        case let .extraModifier(.some(configured)) where verifiedExtraModifier == configured:
            guard additionalModifier == nil || additionalModifier == configured else { return nil }
            return .extraModifier(target, confirmed: additionalModifier == configured)
        default:
            return nil
        }
    }
}
