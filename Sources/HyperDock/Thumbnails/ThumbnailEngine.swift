import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A ScreenCaptureKit window handle, carried across isolation boundaries.
///
/// `SCWindow` is an immutable descriptor handed out by a `SCShareableContent` snapshot;
/// nothing mutates it and it is only ever read. It carries no `Sendable` conformance,
/// so the reason is stated here rather than silently suppressed at each use site.
private nonisolated struct ShareableWindow: @unchecked Sendable {
    let window: SCWindow
}

/// Captures window thumbnails.
///
/// `SCScreenshotManager.captureImage` is the only supported way to do this on macOS 26.
/// `CGWindowListCreateImage` is not merely deprecated but *obsoleted* as of macOS 15, so
/// it will not even compile against this SDK — and it returned nothing for minimised
/// windows anyway, which is precisely the case this feature exists to cover.
///
/// Measured here: a warm capture runs 20–24 ms, a cold first call 55–66 ms, and windows
/// on other Spaces or minimised into the Dock capture successfully and non-blank.
actor ThumbnailEngine {
    static let shared = ThumbnailEngine()

    /// Concurrency saturates quickly — for ten windows, 232 ms serially, 141 ms two at a
    /// time, 133 ms at four, and no further gain beyond that. Going wider only floods
    /// the capture daemon.
    private static let maxConcurrentCaptures = 4
    private static let cacheLimit = 64
    private static let captureAttempts = 3

    private var cache: [CGWindowID: Thumbnail] = [:]

    private init() {}

    nonisolated static func shouldEvict(cacheCount: Int,
                                        alreadyContainsWindow: Bool,
                                        limit: Int = cacheLimit) -> Bool {
        cacheCount >= limit && !alreadyContainsWindow
    }

    // MARK: - Public API

    func cached(_ id: CGWindowID) -> Thumbnail? { cache[id] }

    /// Captures thumbnails for `windows`, four at a time, delivering each through
    /// `onReady` as soon as it lands so tiles fill in progressively rather than the
    /// bubble waiting on the slowest one.
    func capture(_ windows: [WindowInfo],
                 targetWidth: CGFloat,
                 onReady: @escaping @Sendable (CGWindowID, Thumbnail) -> Void) async {
        guard !Task.isCancelled else { return }

        // HyperDock 1.8 displayed its cached prototype before starting the independent
        // load operation. Do the same so a transient ScreenCaptureKit omission never
        // turns a previously captured window back into an empty card.
        for window in windows {
            if let thumbnail = cache[window.id] { onReady(window.id, thumbnail) }
        }

        // One listing for the whole batch. It costs 46–57 ms, so doing it per window —
        // as an earlier version did — added more latency than every capture combined.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false) else {
            Log.thumbnails.error("SCShareableContent failed; is Screen Recording granted?")
            return
        }
        guard !Task.isCancelled else { return }

        var handles: [CGWindowID: ShareableWindow] = [:]
        var freshTitles: [CGWindowID: String] = [:]
        var windowIDs: Set<CGWindowID> = []
        for window in content.windows {
            handles[window.windowID] = ShareableWindow(window: window)
            windowIDs.insert(window.windowID)
            if let title = window.title, !title.isEmpty {
                freshTitles[window.windowID] = title
            }
        }
        // The expensive listing above is already required for capture. Reuse it to keep
        // WindowIndex current rather than making a latency-sensitive hover query repeat
        // the same 46–57 ms ScreenCaptureKit operation merely to obtain optional titles.
        let titleSnapshot = WindowIndex.TitleSnapshot(
            titles: freshTitles,
            windowIDs: windowIDs,
            receivedAt: DispatchTime.now().uptimeNanoseconds,
            sequence: WindowIndex.nextTitleSnapshotSequence()
        )
        await WindowIndex.shared.recordTitleSnapshot(titleSnapshot)

        var pending = windows
        var currentHandles = handles
        for attempt in 0..<Self.captureAttempts where !pending.isEmpty {
            pending = await captureRound(pending,
                                         handles: currentHandles,
                                         targetWidth: targetWidth,
                                         onReady: onReady)
            guard !Task.isCancelled, !pending.isEmpty,
                  attempt + 1 < Self.captureAttempts else { break }

            // Window IDs can reach CGWindowList slightly before ScreenCaptureKit publishes
            // their SCWindow handles. The old helper's per-window operations naturally
            // retried that race; refresh the listing and try the unresolved windows again.
            try? await Task.sleep(for: .milliseconds(90 * (attempt + 1)))
            guard !Task.isCancelled,
                  let refreshed = try? await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false) else { continue }
            currentHandles = Dictionary(uniqueKeysWithValues: refreshed.windows.map {
                ($0.windowID, ShareableWindow(window: $0))
            })
        }
    }

    /// A single high-resolution capture for the full-size hover preview.
    ///
    /// Deliberately bypasses the thumbnail cache in both directions: the grid's small
    /// image would look soft blown up, and storing this large one would evict the
    /// thumbnails the bubble still needs.
    func fullSize(_ window: WindowInfo, targetWidth: CGFloat) async -> Thumbnail? {
        guard !Task.isCancelled,
              let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false),
              let match = content.windows.first(where: { $0.windowID == window.id })
        else { return cache[window.id] }
        guard !Task.isCancelled else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(targetWidth.rounded()))
        configuration.height = max(2, Int((targetWidth / max(window.aspectRatio, 0.05)).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        do {
            let filter = SCContentFilter(desktopIndependentWindow: match)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: configuration)
            guard !Task.isCancelled else { return nil }
            return Thumbnail(image: image, captured: Date(), isLive: window.isOnScreen)
        } catch {
            return cache[window.id]
        }
    }

    /// Drops cached images for windows that no longer exist.
    func prune(keeping live: Set<CGWindowID>) {
        cache = cache.filter { live.contains($0.key) }
    }

    // MARK: - Capture

    /// Runs one capture attempt for a batch and returns only unresolved windows. Four
    /// operations are kept in flight, matching the measured capture-daemon sweet spot.
    private func captureRound(
        _ windows: [WindowInfo],
        handles: [CGWindowID: ShareableWindow],
        targetWidth: CGFloat,
        onReady: @escaping @Sendable (CGWindowID, Thumbnail) -> Void
    ) async -> [WindowInfo] {
        await withTaskGroup(of: (WindowInfo, Thumbnail?).self,
                            returning: [WindowInfo].self) { group in
            var iterator = windows.makeIterator()
            var active = 0
            var unresolved: [WindowInfo] = []

            func startNext() -> Bool {
                guard !Task.isCancelled, let window = iterator.next() else { return false }
                guard let handle = handles[window.id] else {
                    unresolved.append(window)
                    return startNext()
                }
                group.addTask { [weak self] in
                    guard !Task.isCancelled, let self else { return (window, nil) }
                    let thumbnail = await self.performCapture(
                        window, handle: handle, targetWidth: targetWidth
                    )
                    return (window, thumbnail)
                }
                return true
            }

            while active < Self.maxConcurrentCaptures, startNext() { active += 1 }
            while active > 0 {
                if let (window, thumbnail) = await group.next() {
                    active -= 1
                    if let thumbnail, !Task.isCancelled {
                        onReady(window.id, thumbnail)
                    } else {
                        unresolved.append(window)
                    }
                }
                if startNext() { active += 1 }
            }
            return unresolved
        }
    }

    private func performCapture(_ window: WindowInfo,
                                handle: ShareableWindow,
                                targetWidth: CGFloat) async -> Thumbnail? {
        let configuration = SCStreamConfiguration()

        // The returned image is always exactly the requested width × height. With the
        // default aspect-ratio preservation, a mismatched request is letterboxed with
        // fully transparent pixels — which in a grid reads as a correctly sized tile
        // whose content floats, putting the close button and title in the wrong place.
        // So the height comes from the window's own aspect ratio rather than a guess.
        let width = max(2, Int(targetWidth.rounded()))
        let height = max(2, Int((targetWidth / max(window.aspectRatio, 0.05)).rounded()))

        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        do {
            let filter = SCContentFilter(desktopIndependentWindow: handle.window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: configuration)
            guard !Task.isCancelled else { return nil }
            let thumbnail = Thumbnail(image: image, captured: Date(), isLive: window.isOnScreen)
            if Self.shouldEvict(cacheCount: cache.count,
                                alreadyContainsWindow: cache[window.id] != nil) {
                // Captures are a cache, not state. Clearing at the boundary releases all
                // retained CGImages at once and keeps the admission path constant-time.
                cache.removeAll(keepingCapacity: true)
            }
            cache[window.id] = thumbnail
            return thumbnail
        } catch {
            // A window closing mid-capture reports SCStreamErrorInternalError (-3811)
            // with a message about audio/video capture failure. That is a routine race
            // in a hover UI, not a fault worth surfacing — fall back to the last image.
            Log.thumbnails.debug("capture failed for \(window.id): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
