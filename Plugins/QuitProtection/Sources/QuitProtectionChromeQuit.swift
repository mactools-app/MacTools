import ApplicationServices

enum QuitProtectionChromeQuit {
    static let bundleIdentifier = "com.google.Chrome"

    static func menuItem(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.025) == .success,
              let menuBar = read(app, kAXMenuBarAttribute),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
              let menus = children(of: menuBar as! AXUIElement, limit: 2) else { return nil }

        // Chrome exposes the application menu next to the Apple menu. Require
        // the native Quit action and its unmodified Command-Q binding, never
        // infer the action from the menu's position or a localized title.
        let deadline = ContinuousClock.now + .milliseconds(50)
        let keys = [
            kAXRoleAttribute, kAXIdentifierAttribute, kAXMenuItemCmdCharAttribute,
            kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute
        ] as CFArray
        for menuItem in menus {
            guard let submenus = children(of: menuItem, limit: 1),
                  let menu = submenus.first, let items = children(of: menu, limit: 32) else { continue }
            for item in items {
                guard ContinuousClock.now < deadline else { return nil }
                var attributes: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, keys, [], &attributes) == .success,
                      let values = attributes as? [Any], values.count == 5,
                      values[0] as? String == kAXMenuItemRole,
                      isQuitBinding(identifier: values[1] as? String, character: values[2] as? String,
                                    modifiers: values[3] as? Int, isEnabled: values[4] as? Bool) else { continue }
                var owner: pid_t = 0
                if AXUIElementGetPid(item, &owner) == .success, owner == pid { return item }
            }
        }
        return nil
    }

    static func isQuitBinding(identifier: String?, character: String?, modifiers: Int?, isEnabled: Bool?) -> Bool {
        identifier == "terminate:" && character?.lowercased() == "q" && modifiers == 0 && isEnabled == true
    }

    private static func children(of element: AXUIElement, limit: Int) -> [AXUIElement]? {
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &children) == .success else {
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
