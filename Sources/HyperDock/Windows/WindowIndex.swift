import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A process-wide tie-breaker for ScreenCaptureKit results that land in the same
/// monotonic-clock nanosecond. The lock covers the single integer and nothing else.
private nonisolated final class TitleSnapshotSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        if value == 0 { value = 1 }
        return value
    }
}

/// Keeps a current picture of every window on the system, and answers "which windows
/// belong to this application?" fast enough to run on Dock hover.
///
/// Enumeration comes from `CGWindowListCopyWindowInfo`, not from ScreenCaptureKit or
/// Accessibility, for three reasons:
///
///   * It sees every Space. `kAXWindowsAttribute` is filtered to the *current* Space and
///     returns an empty array for an application whose windows are all elsewhere —
///     exactly the windows this feature exists to show.
///   * It is cheap: ~4 ms, against 46–57 ms for a full `SCShareableContent` listing.
///   * It works without Screen Recording permission. Titles do not, which is why the
///     ScreenCaptureKit listing is still consulted — but as an *enrichment*. If that
///     permission is missing the bubble still opens, showing application names in place
///     of window titles, instead of silently doing nothing.
actor WindowIndex {
    static let shared = WindowIndex()

    /// Controls whether a query may pay for optional ScreenCaptureKit enrichment.
    ///
    /// Hover presentation is latency-sensitive and can render useful cards from the
    /// WindowServer data alone. A reconciliation after an explicit window action values
    /// a fresh title table more highly than those 46–57 ms, so it opts in deliberately.
    enum QueryPurpose: Sendable {
        case interactivePreview
        case refreshedSnapshot

        nonisolated var waitsForTitleEnrichment: Bool {
            self == .refreshedSnapshot
        }
    }

    /// One complete title-enrichment snapshot.
    ///
    /// `windowIDs` matters separately from `titles`: a new window absent from an older
    /// snapshot is unknown, not an untitled palette. `receivedAt` bounds stale-id/title
    /// reuse and orders independent ScreenCaptureKit requests by when their result
    /// actually arrived rather than by actor scheduling order.
    nonisolated struct TitleSnapshot: Sendable {
        let titles: [CGWindowID: String]
        let windowIDs: Set<CGWindowID>
        let receivedAt: UInt64
        let sequence: UInt64

        nonisolated func isFresh(now: UInt64, maxAgeNanoseconds: UInt64) -> Bool {
            guard receivedAt > 0, now >= receivedAt else { return false }
            return now - receivedAt <= maxAgeNanoseconds
        }

        nonisolated func preferredTitle(
            for id: CGWindowID,
            windowServerTitle: String,
            now: UInt64,
            maxAgeNanoseconds: UInt64
        ) -> String {
            // WindowServer is the live source. ScreenCaptureKit only fills the common
            // case where privacy leaves kCGWindowName empty.
            if !windowServerTitle.isEmpty { return windowServerTitle }
            guard isFresh(now: now, maxAgeNanoseconds: maxAgeNanoseconds) else { return "" }
            return titles[id] ?? ""
        }

        nonisolated func canClassifyUntitledWindow(
            _ id: CGWindowID,
            now: UInt64,
            maxAgeNanoseconds: UInt64
        ) -> Bool {
            isFresh(now: now, maxAgeNanoseconds: maxAgeNanoseconds)
                && !titles.isEmpty
                && windowIDs.contains(id)
        }
    }

    private static let titleSnapshotSequence = TitleSnapshotSequence()
    private var titleSnapshot = TitleSnapshot(
        titles: [:], windowIDs: [], receivedAt: 0, sequence: 0
    )
    private var titleTask: Task<Void, Never>?
    private let titleSnapshotMaxAgeNanoseconds: UInt64 = 2_000_000_000

    /// Windows confirmed closed, which the window server has not stopped reporting.
    ///
    /// `kCGWindowIsOnscreen` lags the actual close by longer than it takes to rebuild the
    /// bubble: measured, the reconcile that follows a close still sees the window as on
    /// screen, so the ghost check below has nothing to be suspicious about and the card
    /// the user just dismissed comes straight back. Recording the id at the moment the
    /// close is confirmed closes that window of time.
    private var closedIDs: [CGWindowID: Date] = [:]

    /// How long a closed id is believed unconditionally.
    ///
    /// The window server keeps reporting a closed window as *on screen* for a moment after
    /// the fact, so the "an id back on screen has been reused" rule cannot be applied
    /// immediately — it would retract the close the instant it was recorded. Ids are not
    /// recycled anywhere near this fast.
    private let closedIDGrace: TimeInterval = 5.0
    /// Closed WindowServer records can persist indefinitely. Keep the suppression set
    /// finite so a session that closes thousands of windows cannot grow it forever.
    private let closedIDLimit = 512

    private init() {}

    // MARK: - Lifecycle

    func startTracking() {
        Task { await refresh() }
    }

    /// Refreshes the title table. Overlapping calls coalesce onto one listing.
    func refresh() async {
        if let existing = titleTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false) else { return }
            var fresh: [CGWindowID: String] = [:]
            var windowIDs: Set<CGWindowID> = []
            for window in content.windows {
                windowIDs.insert(window.windowID)
                if let title = window.title, !title.isEmpty { fresh[window.windowID] = title }
            }
            let snapshot = TitleSnapshot(
                titles: fresh,
                windowIDs: windowIDs,
                receivedAt: DispatchTime.now().uptimeNanoseconds,
                sequence: Self.nextTitleSnapshotSequence()
            )
            await self.recordTitleSnapshot(snapshot)
        }
        titleTask = task
        await task.value
        titleTask = nil
    }

    nonisolated static func shouldAcceptTitleSnapshot(
        currentReceivedAt: UInt64,
        currentSequence: UInt64,
        candidateReceivedAt: UInt64,
        candidateSequence: UInt64
    ) -> Bool {
        if candidateReceivedAt != currentReceivedAt {
            return candidateReceivedAt > currentReceivedAt
        }
        return candidateSequence > currentSequence
    }

    nonisolated static func nextTitleSnapshotSequence() -> UInt64 {
        titleSnapshotSequence.next()
    }

    /// Accepts title enrichment from a ScreenCaptureKit listing another subsystem already
    /// had to perform. Older independent requests cannot overwrite a newer result.
    func recordTitleSnapshot(_ candidate: TitleSnapshot) {
        guard Self.shouldAcceptTitleSnapshot(
            currentReceivedAt: titleSnapshot.receivedAt,
            currentSequence: titleSnapshot.sequence,
            candidateReceivedAt: candidate.receivedAt,
            candidateSequence: candidate.sequence
        ) else { return }
        titleSnapshot = candidate
    }

    /// Records that a window is gone, for callers that watched it go.
    ///
    /// Only call this once the close is *confirmed* — a press that merely returned success
    /// is not enough, because an application may put up a save sheet instead of closing.
    func noteClosed(_ id: CGWindowID) {
        if closedIDs.count >= closedIDLimit, closedIDs[id] == nil,
           let oldest = closedIDs.min(by: { $0.value < $1.value })?.key {
            closedIDs.removeValue(forKey: oldest)
        }
        closedIDs[id] = Date()
    }

    // MARK: - Queries

    /// Every window belonging to `pid`, ordered for display.
    func windows(forPID pid: pid_t,
                 preferences: WindowQueryOptions,
                 purpose: QueryPurpose = .interactivePreview) async -> [WindowInfo] {
        if purpose.waitsForTitleEnrichment {
            await refresh()
        }

        let titleSnapshot = titleSnapshot
        let titleNow = DispatchTime.now().uptimeNanoseconds
        let spaceMap = Self.buildSpaceMap()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard pid != ownPID else { return [] }

        // .optionAll rather than .optionOnScreenOnly: minimised windows and windows on
        // other Spaces are absent from the on-screen list, and they are the point.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        // The window server reuses ids. One that turns up on screen again, long enough
        // after the close that this cannot be the server still catching up, is a new
        // window wearing an old number — so stop treating it as closed.
        if !closedIDs.isEmpty {
            let cutoff = Date().addingTimeInterval(-closedIDGrace)
            for entry in raw where (entry[kCGWindowIsOnscreen as String] as? Bool) == true {
                guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                      let closedAt = closedIDs[id], closedAt < cutoff else { continue }
                closedIDs[id] = nil
            }
        }
        let closed = Set(closedIDs.keys)

        var results: [WindowInfo] = raw.enumerated().compactMap { stackingIndex, entry -> WindowInfo? in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  !closed.contains(id),
                  // Layer 0 is the ordinary document/window layer; anything else is a
                  // panel, menu, tooltip or shadow.
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            let frame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                               width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)

            // Tool palettes, tooltips and stray shadows are never what a person means
            // by "a window".
            guard frame.width >= 80, frame.height >= 60 else { return nil }

            let applicationName = entry[kCGWindowOwnerName as String] as? String ?? ""
            // Prefer WindowServer's live name. ScreenCaptureKit is a freshness-bounded
            // fallback for the privacy mode in which kCGWindowName is empty.
            let title = titleSnapshot.preferredTitle(
                for: id,
                windowServerTitle: entry[kCGWindowName as String] as? String ?? "",
                now: titleNow,
                maxAgeNanoseconds: titleSnapshotMaxAgeNanoseconds
            )

            // Surfaces the window server places on no Space at all are not windows the
            // user can be sent to, whatever they call themselves.
            guard spaceMap.isPlaced(id) else { return nil }

            let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            let placement = spaceMap.placement(of: id)

            // A window belonging to the current Space that is not on screen must be
            // minimised or its application hidden; a window on another Space is simply
            // elsewhere. Minimised windows keep their Space membership, which is what
            // makes this distinction reliable.
            let minimized = !onScreen && placement.isOnCurrentSpace

            if title.isEmpty && !preferences.includePalettes {
                // Only a fresh, complete snapshot that contains this exact id can call it
                // an untitled helper. A window missing from an older snapshot is new or
                // unknown and must remain visible until thumbnail capture enriches it.
                if titleSnapshot.canClassifyUntitledWindow(
                    id,
                    now: titleNow,
                    maxAgeNanoseconds: titleSnapshotMaxAgeNanoseconds
                ) { return nil }
            }

            return WindowInfo(
                id: id,
                pid: pid,
                title: title,
                applicationName: applicationName,
                frame: frame,
                stackingIndex: stackingIndex,
                spaceNumber: placement.spaceNumber,
                isOnCurrentSpace: placement.isOnCurrentSpace,
                isMinimized: minimized,
                isOnScreen: onScreen
            )
        }

        results = results.filter { window in
            if window.isMinimized && !preferences.includeMinimizedAndHidden { return false }
            if !window.isOnCurrentSpace && !window.isMinimized
                && !preferences.includeAllSpaces { return false }
            return true
        }

        results = await Self.dropGhostWindows(from: results, pid: pid, spaceMap: spaceMap)

        return Self.sort(results, by: preferences)
    }

    /// Removes ghost windows: registered on a Space yet rendered on none.
    ///
    /// The window server's full per-Space listing (option 0x7) reports three kinds of
    /// window identically — real ones, minimised ones, and surfaces an application
    /// registered once and never shows again. Only the last kind must go, and it is
    /// endemic: WeChat keeps a titled 280×380 panel registered on a Space it never
    /// draws on (the "second card" for a one-window app), Chrome Canary keeps two or
    /// three tab-preview strips registered (four real windows became seven cards, the
    /// 1062×136 strip wrecking the row's shape), closed TextEdit windows linger in
    /// `CGWindowListCopyWindowInfo` indefinitely, and Surge parks a dismissed "更新"
    /// dialog on whatever Space it died on.
    ///
    /// The 0x2 listing is the separator: it holds exactly the windows a Space would
    /// render, measured as excluding every ghost above while keeping real windows on
    /// every Space, current or not. Two legitimate states also fall outside it and are
    /// exempted:
    ///
    ///  * a **hidden application** (⌘H) removes all its windows from 0x2 — the owner's
    ///    `isHidden` covers the lot;
    ///  * a **minimised window** leaves 0x2 too — Accessibility vouches for those, the
    ///    same tiebreak this filter has always used. An unreadable AX list means "no
    ///    opinion" and nothing is dropped; an empty list is an answer (measured on
    ///    WeChat, which vends nothing to Accessibility while its ghost is registered),
    ///    and with it every off-screen absentee goes.
    private static func dropGhostWindows(from windows: [WindowInfo],
                                         pid: pid_t,
                                         spaceMap: SpaceMap) async -> [WindowInfo] {
        let suspect = windows.contains { !$0.isOnScreen && !spaceMap.isPresent($0.id) }
        guard suspect else { return windows }

        let ownerHidden = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
        }
        guard !ownerHidden else { return windows }

        guard let live = await AXCore.shared.liveWindowIDs(pid: pid) else { return windows }

        return windows.filter { window in
            guard !window.isOnScreen, !spaceMap.isPresent(window.id) else { return true }
            return live.contains(window.id)
        }
    }

    private static func sort(_ windows: [WindowInfo],
                             by options: WindowQueryOptions) -> [WindowInfo] {
        var sorted = windows

        switch options.order {
        case .creationTime:
            // Window ids increase monotonically, so a larger id is a newer window.
            sorted.sort { $0.id < $1.id }
        case .recentUsage:
            // WindowServer's front-to-back order is the surviving system equivalent of
            // the original helper's per-window recent-usage order.
            sorted.sort { $0.stackingIndex < $1.stackingIndex }
        }

        if options.currentSpaceFirst {
            // A stable partition, so the chosen order survives within each group.
            let current = sorted.filter(\.isOnCurrentSpace)
            let elsewhere = sorted.filter { !$0.isOnCurrentSpace }
            sorted = current + elsewhere
        }
        return sorted
    }

    // MARK: - Space mapping

    /// Where a window sits, in the terms the UI cares about.
    nonisolated struct Placement: Sendable {
        let spaceNumber: Int?
        let isOnCurrentSpace: Bool
    }

    /// A reverse index from window to Space.
    ///
    /// Built by asking each Space for its windows rather than each window for its
    /// Spaces: the per-Space direction sees Spaces the user is not currently viewing,
    /// and one call per Space is far cheaper than one per window.
    nonisolated struct SpaceMap: Sendable {
        let windowToNumber: [CGWindowID: Int]
        let currentSpaceWindows: Set<CGWindowID>
        /// Every window the window server places on *some* Space, full-screen ones
        /// included. Membership here is what separates a real window from a surface an
        /// application merely keeps around — see `isPlaced`.
        let placedWindows: Set<CGWindowID>
        /// Windows some Space would actually render (option 0x2): real windows whether
        /// or not their Space is showing. A placed window missing from here is either
        /// minimised, belongs to a hidden application, or is a ghost surface.
        let presentWindows: Set<CGWindowID>
        let available: Bool

        /// Whether this window lives on a Space at all.
        ///
        /// A window that belongs to no Space cannot be shown, raised or switched to —
        /// there is nowhere to switch *to*. Measured on Termius and Lark, which keep
        /// several such surfaces around and give them real titles like "Termius" and
        /// "Termius - Settings", so nothing else filters them out: clicking one switched
        /// no Space, failed twelve raise attempts, and fell through to activating the
        /// application, which is what made it appear on the desktop the user was already
        /// on instead of the one holding the window they asked for.
        ///
        /// Real windows always have one. Verified across TextEdit, Ghostty, Sublime Text
        /// and Finder, including a minimised window, which keeps its Space.
        func isPlaced(_ window: CGWindowID) -> Bool {
            guard available else { return true }
            return placedWindows.contains(window)
        }

        func isPresent(_ window: CGWindowID) -> Bool {
            guard available else { return true }
            return presentWindows.contains(window)
        }

        func placement(of window: CGWindowID) -> Placement {
            guard available else {
                // Without the Space SPI the app still works; it just cannot label or
                // distinguish off-Space windows.
                return Placement(spaceNumber: nil, isOnCurrentSpace: true)
            }
            return Placement(spaceNumber: windowToNumber[window],
                             isOnCurrentSpace: currentSpaceWindows.contains(window))
        }
    }

    nonisolated static func buildSpaceMap() -> SpaceMap {
        let displays = CGS.managedDisplaySpaces()
        guard !displays.isEmpty else {
            return SpaceMap(windowToNumber: [:], currentSpaceWindows: [],
                            placedWindows: [], presentWindows: [], available: false)
        }

        var numbers: [CGWindowID: Int] = [:]
        var current: Set<CGWindowID> = []
        var placed: Set<CGWindowID> = []
        var present: Set<CGWindowID> = []

        for display in displays {
            for space in display.spaces {
                let windows = CGS.windows(onSpace: space.id)
                placed.formUnion(windows)
                present.formUnion(CGS.windows(onSpace: space.id, visibleOnly: true))
                if space.isCurrent { current.formUnion(windows) }
                // A full-screen Space has no user-visible desktop number.
                guard space.type == 0 else { continue }
                for window in windows where numbers[window] == nil {
                    numbers[window] = space.number
                }
            }
        }
        return SpaceMap(windowToNumber: numbers, currentSpaceWindows: current,
                        placedWindows: placed, presentWindows: present, available: true)
    }
}

/// The subset of user preferences that shapes a window query, snapshotted so the actor
/// never reaches back to the main actor mid-query.
nonisolated struct WindowQueryOptions: Sendable {
    let includeAllSpaces: Bool
    let includeMinimizedAndHidden: Bool
    let includePalettes: Bool
    let order: WindowOrder
    let currentSpaceFirst: Bool

    @MainActor
    static func current() -> WindowQueryOptions {
        let preferences = Preferences.shared
        return WindowQueryOptions(
            includeAllSpaces: preferences.includeWindowsFromAllSpaces,
            includeMinimizedAndHidden: preferences.includeMinimizedAndHidden,
            includePalettes: preferences.includePalettes,
            order: preferences.windowOrder,
            currentSpaceFirst: preferences.currentSpaceWindowsFirst
        )
    }
}
