import CoreGraphics
import Foundation

// Confined to the monitor's main run loop. Observation times are conservative:
// they establish when an app was known to be active, not its actual activation time.
struct DockClickGestureTracker {
    private struct PendingClick {
        let location: CGPoint
        let timestamp: CGEventTimestamp
        let frontmostApplication: DockFrontmostApplication
    }

    private var observedApplication: DockFrontmostApplication?
    private var observedAt: CGEventTimestamp = .max
    private var pendingClick: PendingClick?
    private(set) var generation = 0

    mutating func reset(frontmostApplication: DockFrontmostApplication?, at timestamp: CGEventTimestamp) {
        observedApplication = frontmostApplication
        observedAt = timestamp
        pendingClick = nil
        generation &+= 1
    }

    mutating func handle(
        type: CGEventType,
        event: CGEvent,
        frontmostApplication: DockFrontmostApplication?,
        observedAt timestamp: CGEventTimestamp
    ) -> DockFrontmostApplication? {
        // A workspace notification may still be queued when a mouse event arrives.
        // Never promote a newly sampled app to the pre-click foreground app.
        if frontmostApplication != observedApplication {
            reset(frontmostApplication: frontmostApplication, at: timestamp)
        }

        switch type {
        case .leftMouseDown:
            pendingClick = nil
            guard DockClickModifierPolicy.isPlainClick(flags: event.flags),
                  event.timestamp > observedAt,
                  let observedApplication
            else {
                return nil
            }
            pendingClick = PendingClick(
                location: event.location,
                timestamp: event.timestamp,
                frontmostApplication: observedApplication
            )
        case .leftMouseDragged:
            if let pendingClick,
               !DockClickGesturePolicy.isWithinMaximumDistance(
                   downLocation: pendingClick.location,
                   currentLocation: event.location
               ) {
                self.pendingClick = nil
            }
        case .leftMouseUp:
            defer { pendingClick = nil }
            guard let pendingClick,
                  event.timestamp >= pendingClick.timestamp,
                  DockClickModifierPolicy.isPlainClick(flags: event.flags),
                  DockClickGesturePolicy.isCompletedClick(
                      downLocation: pendingClick.location,
                      upLocation: event.location,
                      duration: Double(event.timestamp - pendingClick.timestamp) / 1_000_000_000
                  )
            else {
                return nil
            }
            return pendingClick.frontmostApplication
        default:
            break
        }
        return nil
    }
}
