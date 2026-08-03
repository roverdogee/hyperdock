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

        await withTaskGroup(of: Void.self) { group in
            var iterator = windows.makeIterator()
            var active = 0

            // A sliding window: keep exactly `maxConcurrentCaptures` in flight, starting
            // the next capture each time one finishes.
            func startNext() -> Bool {
                guard !Task.isCancelled else { return false }
                while let window = iterator.next() {
                    guard let handle = handles[window.id] else { continue }
                    group.addTask { [weak self] in
                        guard !Task.isCancelled, let self else { return }
                        if let thumbnail = await self.performCapture(
                            window, handle: handle, targetWidth: targetWidth
                        ), !Task.isCancelled {
                            onReady(window.id, thumbnail)
                        }
                    }
                    return true
                }
                return false
            }

            while active < Self.maxConcurrentCaptures, startNext() { active += 1 }
            while active > 0 {
                await group.next()
                active -= 1
                if startNext() { active += 1 }
            }
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
            return cache[window.id]
        }
    }
}
