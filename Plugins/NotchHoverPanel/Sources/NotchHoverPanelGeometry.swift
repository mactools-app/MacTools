import AppKit
import CoreGraphics

/// Screen data needed to resolve the notch trigger without retaining `NSScreen`.
struct NotchHoverScreenSnapshot: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?
    let isBuiltin: Bool
    let isMain: Bool
    let isInMirrorSet: Bool
}

struct NotchHoverDisplay: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let notchFrame: CGRect
    let triggerRects: [CGRect]
}

enum NotchHoverGeometry {
    static let defaultTriggerWidth: CGFloat = 52
    static let minimumTriggerWidth: CGFloat = 24
    static let maximumTriggerWidth: CGFloat = 120
    static let allowedTriggerWidthRange: ClosedRange<Double> = 24...120
    static let triggerWidthStep: Double = 4

    static let defaultVerticalTriggerReach: CGFloat = 72
    static let minimumVerticalTriggerReach: CGFloat = 24
    static let maximumVerticalTriggerReach: CGFloat = 160
    static let allowedVerticalTriggerReachRange: ClosedRange<Double> = 24...160
    static let verticalTriggerReachStep: Double = 8

    static func displays(
        from screens: [NotchHoverScreenSnapshot],
        triggerWidth: CGFloat,
        verticalTriggerReach: CGFloat = defaultVerticalTriggerReach,
        enableBelowTrigger: Bool = true
    ) -> [NotchHoverDisplay] {
        screens.compactMap {
            display(
                for: $0,
                triggerWidth: triggerWidth,
                verticalTriggerReach: verticalTriggerReach,
                enableBelowTrigger: enableBelowTrigger
            )
        }
    }

    static func display(
        for screen: NotchHoverScreenSnapshot,
        triggerWidth: CGFloat,
        verticalTriggerReach: CGFloat = defaultVerticalTriggerReach,
        enableBelowTrigger: Bool = true
    ) -> NotchHoverDisplay? {
        // Mirrored secondary screens repeat the built-in display's menu bar and
        // would otherwise create two competing notch triggers.
        guard !screen.isInMirrorSet || screen.isMain else { return nil }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty,
              !rightArea.isEmpty else { return nil }

        let topBandHeight = max(leftArea.height, rightArea.height)
        guard topBandHeight > 0 else { return nil }

        let notchWidth = screen.frame.width - leftArea.width - rightArea.width
        guard notchWidth > 0 else { return nil }

        let bandWidth = min(max(triggerWidth, minimumTriggerWidth), maximumTriggerWidth)
        let verticalReach = min(
            max(verticalTriggerReach, minimumVerticalTriggerReach),
            maximumVerticalTriggerReach
        )
        let notchFrame = CGRect(
            x: screen.frame.minX + leftArea.width,
            y: screen.frame.maxY - topBandHeight,
            width: notchWidth,
            height: topBandHeight
        )

        let leftTrigger = CGRect(
            x: notchFrame.minX - bandWidth,
            y: notchFrame.minY,
            width: bandWidth,
            height: notchFrame.height
        ).intersection(screen.frame)
        let rightTrigger = CGRect(
            x: notchFrame.maxX,
            y: notchFrame.minY,
            width: bandWidth,
            height: notchFrame.height
        ).intersection(screen.frame)

        // Extend the trigger directly below the notch so moving upward toward
        // the notch from the content area also reveals the panel. The lower
        // trigger can be disabled independently of the side triggers.
        var triggers = [leftTrigger, rightTrigger]
        if enableBelowTrigger {
            let belowNotchTrigger = CGRect(
                x: notchFrame.minX,
                y: notchFrame.minY - verticalReach,
                width: notchFrame.width,
                height: notchFrame.height + verticalReach
            ).intersection(screen.frame)
            triggers.append(belowNotchTrigger)
        }
        triggers = triggers.filter { !$0.isEmpty }
        guard !triggers.isEmpty else { return nil }

        return NotchHoverDisplay(
            displayID: screen.displayID,
            screenFrame: screen.frame,
            notchFrame: notchFrame,
            triggerRects: triggers
        )
    }

    static func isPointerActive(
        _ point: CGPoint,
        triggers: [CGRect],
        notchFrame: CGRect,
        panelFrame: CGRect?
    ) -> Bool {
        if triggers.contains(where: { $0.contains(point) }) {
            return true
        }

        if let panelFrame {
            let panelHitArea = panelFrame.insetBy(dx: -8, dy: -8)
            if panelHitArea.contains(point) {
                return true
            }

            // Keep the short strip between the menu bar and a slid-out panel
            // active so crossing it does not dismiss the panel.
            let corridor = CGRect(
                x: notchFrame.minX,
                y: panelFrame.minY,
                width: notchFrame.width,
                height: max(0, notchFrame.minY + 8 - panelFrame.minY)
            )
            if corridor.contains(point) {
                return true
            }
        }

        return false
    }
}

@MainActor
enum NotchHoverScreenCatalog {
    static func snapshots() -> [NotchHoverScreenSnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }

            let displayID = screenNumber.uint32Value
            return NotchHoverScreenSnapshot(
                displayID: displayID,
                frame: screen.frame,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                isMain: CGDisplayIsMain(displayID) != 0,
                isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0
            )
        }
    }
}
