import ApplicationServices

enum QuitProtectionChromeQuit {
    static func handles(bundleIdentifier: String?) -> Bool {
        switch bundleIdentifier {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary":
            true
        default:
            false
        }
    }

    // The worker finishes reading before it hands this retained element to the
    // main actor. The only subsequent use is a single, bounded press.
    struct MenuItem: @unchecked Sendable {
        fileprivate let element: AXUIElement

        @MainActor func press() -> AXError {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    static func requiresRecoveryGuidance(afterPress result: AXError) -> Bool {
        switch result {
        case .invalidUIElement, .actionUnsupported, .illegalArgument, .notImplemented, .apiDisabled:
            return true
        default:
            // A messaging timeout may mean the action was already delivered.
            return false
        }
    }

    enum Lookup: Sendable {
        case menuItem(MenuItem)
        case reassigned
        case unavailable
    }

    static func lookup(in pid: pid_t) -> Lookup {
        let deadline = ContinuousClock.now + .milliseconds(50)
        let app = AXUIElementCreateApplication(pid)
        guard configureTimeout(app, deadline: deadline),
              let menuBar = read(app, kAXMenuBarAttribute),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
              let menus = children(of: menuBar as! AXUIElement, limit: 2, deadline: deadline) else { return .unavailable }

        // Chrome exposes the application menu next to the Apple menu. Require
        // the native Quit action and its unmodified Command-Q binding, never
        // infer the action from the menu's position or a localized title.
        let keys = [
            kAXRoleAttribute, kAXIdentifierAttribute, kAXMenuItemCmdCharAttribute,
            kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute
        ] as CFArray
        for menuItem in menus {
            guard let submenus = children(of: menuItem, limit: 1, deadline: deadline),
                  let menu = submenus.first,
                  let items = children(of: menu, limit: 32, deadline: deadline) else { continue }
            for item in items {
                guard configureTimeout(item, deadline: deadline) else { return .unavailable }
                var attributes: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, keys, [], &attributes) == .success,
                      let values = attributes as? [Any], values.count == 5,
                      values[0] as? String == kAXMenuItemRole,
                      values[1] as? String == "terminate:" else { continue }
                var owner: pid_t = 0
                guard AXUIElementGetPid(item, &owner) == .success, owner == pid, ContinuousClock.now < deadline
                else { return .unavailable }
                switch binding(character: values[2] as? String, modifiers: values[3] as? Int, isEnabled: values[4] as? Bool) {
                case .standard:
                    guard AXUIElementSetMessagingTimeout(item, 0.025) == .success else { return .unavailable }
                    return .menuItem(MenuItem(element: item))
                case .reassigned: return .reassigned
                case .unavailable: return .unavailable
                }
            }
        }
        return .unavailable
    }

    enum Binding {
        case standard, reassigned, unavailable
    }

    static func binding(character: String?, modifiers: Int?, isEnabled: Bool?) -> Binding {
        guard isEnabled == true, let character else { return .unavailable }
        if character.isEmpty { return .reassigned }
        guard let modifiers else { return .unavailable }
        return character.lowercased() == "q" && modifiers == 0 ? .standard : .reassigned
    }

    private static func configureTimeout(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        let seconds = min(0.025, remaining / .seconds(1))
        return AXUIElementSetMessagingTimeout(element, Float(seconds)) == .success
    }

    private static func children(
        of element: AXUIElement, limit: Int, deadline: ContinuousClock.Instant
    ) -> [AXUIElement]? {
        var children: CFArray?
        guard configureTimeout(element, deadline: deadline),
              AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &children) == .success else {
            return nil
        }
        return children as? [AXUIElement]
    }

    private static func read(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
