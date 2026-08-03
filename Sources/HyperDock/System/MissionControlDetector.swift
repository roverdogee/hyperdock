import AppKit

/// Whether Mission Control (or App Exposé) is currently presented.
///
/// While it is up, HyperDock must get out of the way entirely: the Dock's accessibility
/// tree keeps reporting its tiles at their usual positions even though nothing of the
/// Dock is visible, so the hover watcher would happily open a preview bubble *on top of*
/// Mission Control, and the event tap would treat clicks near the bottom of the screen
/// as Dock clicks and swallow them — measured as windows that could not be selected in
/// Mission Control while HyperDock was running.
///
/// Detection: while presented, the Dock owns an on-screen display-sized window at window
/// level 18 per display (measured on macOS 26: a 2560x1440 backdrop, gone the moment
/// Mission Control closes). Level 18 specifically, and not 20: merely *revealing* the
/// auto-hidden Dock also puts a display-wide Dock window on screen, but at level 20 —
/// counting that level made this detector fire the instant the user summoned the Dock,
/// which shut down the very hover previews it exists to protect.
///
/// The check costs one window-list query, so callers on hot paths (pointer moves, scroll
/// bursts) share a cached answer for a short interval instead of asking every time.
///
/// A stale answer is refreshed before the triggering event is classified. Returning the
/// old `false` while a background refresh runs would let exactly that first Mission
/// Control click fall into HyperDock's Dock/drag handlers and potentially be swallowed.
@MainActor
enum MissionControlDetector {

    enum RefreshDecision: Equatable, Sendable {
        case useCachedValue
        case measureNow
    }

    private static var cachedAnswer = false
    private static var cachedAt = Date.distantPast
    /// Long enough to absorb a burst of pointer events, short enough that a freshly
    /// opened Mission Control is noticed before the user's pointer reaches a tile.
    private static let cacheLifetime: TimeInterval = 0.25

    nonisolated static func refreshDecision(
        now: Date,
        cachedAt: Date,
        cacheLifetime: TimeInterval
    ) -> RefreshDecision {
        guard now.timeIntervalSince(cachedAt) >= cacheLifetime else {
            return .useCachedValue
        }
        return .measureNow
    }

    static var isActive: Bool {
        let now = Date()
        if refreshDecision(
            now: now,
            cachedAt: cachedAt,
            cacheLifetime: cacheLifetime
        ) == .measureNow {
            cachedAt = now
            cachedAnswer = measure()
        }
        return cachedAnswer
    }

    private static func measure() -> Bool {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }

        // The smallest display bounds on this machine, as the threshold for "covers a
        // display". Recomputing per call keeps hot-unplugged displays from skewing it.
        let smallestDisplayWidth = NSScreen.screens.map(\.frame.width).min() ?? 1024

        for entry in entries {
            guard (entry[kCGWindowOwnerName as String] as? String) == "Dock",
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 18,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= smallestDisplayWidth
            else { continue }
            return true
        }
        return false
    }
}
