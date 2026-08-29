import Foundation
import CoreGraphics

/// Dynamic bindings to the private CoreGraphics / SkyLight "CGS" window-server SPI.
///
/// There is no public API that answers "which Space is this window on?", which the
/// preview bubble needs in order to draw the Space number over off-Space windows.
/// The real implementations live in SkyLight.framework as `SLS*`; CoreGraphics
/// re-exports them as `CGS*` (verified: `dyld_info -exports` on CoreGraphics prints
/// `[re-export] _CGSCopySpacesForWindows (_SLSCopySpacesForWindows from SkyLight)`).
///
/// Everything here resolves through `dlsym` rather than a link-time reference so that
/// a future macOS renaming a symbol degrades this feature instead of preventing launch.
/// Every entry point returns an optional and every caller must tolerate `nil`.
///
/// `nonisolated` because the project builds with `-default-isolation=MainActor` and
/// these are called from the window-index actor, off the main thread.
nonisolated enum CGS {

    // MARK: - Symbol resolution

    typealias ConnectionID = Int32
    typealias SpaceID = UInt64

    /// `RTLD_DEFAULT` — search every image already loaded in the process.
    /// `nonisolated(unsafe)` is required: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// a plain `static let` of a raw pointer is a hard "not concurrency-safe" error.
    private nonisolated(unsafe) static let handle = UnsafeMutableRawPointer(bitPattern: -2)

    /// `@convention(c)` function pointers are already Sendable and must NOT be marked
    /// `nonisolated(unsafe)` — doing so produces a warning.
    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    // MARK: - Bound functions

    private static let _mainConnectionID =
        resolve("CGSMainConnectionID", as: (@convention(c) () -> ConnectionID).self)

    private static let _copyManagedDisplaySpaces =
        resolve("CGSCopyManagedDisplaySpaces", as: (@convention(c) (ConnectionID) -> Unmanaged<CFArray>?).self)

    private static let _copySpacesForWindows =
        resolve("CGSCopySpacesForWindows",
                as: (@convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?).self)

    private static let _copyWindowsWithOptionsAndTags =
        resolve("CGSCopyWindowsWithOptionsAndTags",
                as: (@convention(c) (ConnectionID, UInt32, CFArray, UInt32,
                                     UnsafeMutablePointer<UInt64>,
                                     UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?).self)

    private static let _moveWindowsToManagedSpace =
        resolve("CGSMoveWindowsToManagedSpace",
                as: (@convention(c) (ConnectionID, CFArray, SpaceID) -> Void).self)

    private static let _getConnectionIDForPSN =
        resolve("CGSGetConnectionIDForPSN",
                as: (@convention(c) (ConnectionID, UnsafeRawPointer, UnsafeMutablePointer<ConnectionID>) -> Int32).self)

    private static let _setWindowAlpha =
        resolve("SLSSetWindowAlpha",
                as: (@convention(c) (ConnectionID, CGWindowID, Float) -> Int32).self)

    /// True when the Space SPI resolved and the feature can be offered at all.
    static var isAvailable: Bool {
        _mainConnectionID != nil && _copyManagedDisplaySpaces != nil
    }

    static var connectionID: ConnectionID? {
        _mainConnectionID?()
    }

    /// Temporarily changes one WindowServer surface's opacity.
    @discardableResult
    static func setWindowAlpha(_ window: CGWindowID, _ alpha: Float) -> Bool {
        guard let cid = connectionID, let setAlpha = _setWindowAlpha else { return false }
        return setAlpha(cid, window, alpha) == 0
    }

    /// Finds the Dock's small app-name tooltip near one tile.
    /// Coordinates are top-left-origin, matching both AX and CGWindow dictionaries.
    static func dockTooltipWindows(near tile: CGRect) -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerName as String] as? String) == "Dock",
                  (entry[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.width >= 20, frame.width <= 500,
                  frame.height >= 12, frame.height <= 140,
                  abs(frame.midX - tile.midX) <= max(180, tile.width * 2.5),
                  frame.minY >= tile.minY - 180,
                  frame.maxY <= tile.maxY + 40
            else { return nil }
            return id
        }
    }

    // MARK: - Space selector bits
    //
    // Measured on macOS 26.5.2, not folklore: selectors 0x1, 0x2, 0x3 and 0x4 used
    // alone ALL return an empty array. The 0x4 "user space" bit is mandatory and must
    // be OR'd into whatever else you ask for.

    /// Every Space a window belongs to.
    private static let selectorAllSpaces: Int32 = 0x7

    // MARK: - Display / Space topology

    /// One entry per Space, in Mission Control's left-to-right order.
    nonisolated struct SpaceEntry: Sendable, Identifiable {
        let id: SpaceID
        /// The number the user sees in Mission Control (1-based, per display,
        /// counting user Spaces only).
        let number: Int
        /// 0 = normal user Space, 4 = a full-screen app's Space.
        let type: Int
        let isCurrent: Bool
    }

    nonisolated struct DisplaySpaces: Sendable {
        /// Display UUID string; matches `CGDisplayCreateUUIDFromDisplayID`.
        let displayIdentifier: String
        let spaces: [SpaceEntry]
        var currentSpace: SpaceEntry? { spaces.first { $0.isCurrent } }
    }

    /// Snapshot of every display's Space list.
    ///
    /// The "Spaces" array order IS the Mission Control order and deliberately is not
    /// sorted by id (observed here: 3, 5, 4, 6, 7, 8, 9, 10, 12). Never derive the
    /// user-visible number by sorting ids.
    static func managedDisplaySpaces() -> [DisplaySpaces] {
        guard let cid = connectionID,
              let raw = _copyManagedDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let currentID = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            let rawSpaces = display["Spaces"] as? [[String: Any]] ?? []

            var userSpaceNumber = 0
            let spaces: [SpaceEntry] = rawSpaces.compactMap { space in
                guard let id = space["ManagedSpaceID"] as? Int else { return nil }
                let type = space["type"] as? Int ?? 0
                // Full-screen Spaces (type 4) occupy a slot but are not numbered
                // desktops, so they must not advance the user-visible counter.
                if type == 0 { userSpaceNumber += 1 }
                return SpaceEntry(id: SpaceID(id),
                                  number: type == 0 ? userSpaceNumber : 0,
                                  type: type,
                                  isCurrent: id == currentID)
            }
            return DisplaySpaces(displayIdentifier: identifier, spaces: spaces)
        }
    }

    // MARK: - Window → Space

    /// The Spaces a single window belongs to.
    ///
    /// Call this **once per window**. `CGSCopySpacesForWindows` returns the
    /// de-duplicated UNION of every window passed in, not a parallel array — batching
    /// silently produces wrong Space badges. It costs ~0.011 ms, so per-window is free.
    static func spaces(forWindow window: CGWindowID) -> [SpaceID] {
        guard let cid = connectionID, let copy = _copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        guard let result = copy(cid, selectorAllSpaces, ids)?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return result.map { SpaceID($0.uint64Value) }
    }

    /// The Space that must be switched to before a window can be reached, or `nil` when
    /// it is already reachable.
    ///
    /// Answered from live window-server state, never from a cached snapshot: the current
    /// Space can change between a preview bubble opening and the user clicking in it, and
    /// switching based on a stale reading moves *away* from the window — after which
    /// Accessibility cannot see it at all and the raise simply fails.
    ///
    /// Returns `nil` for a minimised window too: those keep their Space membership but do
    /// not need a switch, since unminimising brings them to wherever the user is.
    static func spaceToReach(window: CGWindowID) -> SpaceID? {
        let home = spaces(forWindow: window)
        guard !home.isEmpty else { return nil }

        var currentSpaces: Set<SpaceID> = []
        for display in managedDisplaySpaces() {
            if let current = display.currentSpace { currentSpaces.insert(current.id) }
        }
        // Already on a Space the user is looking at: nothing to do.
        guard !home.contains(where: { currentSpaces.contains($0) }) else { return nil }
        return home.first
    }

    /// A real window that can make application activation follow to a Space.
    ///
    /// The window id matters as much as the Space id. Applications such as Surge retire
    /// and recreate their main window while a preview is open; designating the stale card
    /// id cannot point activation at the replacement window.
    struct SpaceActivationTarget: Sendable, Equatable {
        let space: SpaceID
        let windowID: CGWindowID
        let windowArea: CGFloat
    }

    /// Prefers the clicked window while it is still live, otherwise the largest live
    /// sibling. Kept pure so the stale-window rule has a deterministic regression test.
    static func preferredActivationTarget(
        clickedWindowID: CGWindowID,
        directDestination: SpaceID?,
        fallbackCandidates: [SpaceActivationTarget]
    ) -> SpaceActivationTarget? {
        if let directDestination {
            return SpaceActivationTarget(space: directDestination,
                                         windowID: clickedWindowID,
                                         windowArea: .greatestFiniteMagnitude)
        }
        return fallbackCandidates.max { $0.windowArea < $1.windowArea }
    }

    /// Whether an unplaced surface plausibly replaced the previewed window.
    ///
    /// Applications also own large legitimate overlays. Matching against the clicked
    /// frame lets the post-selection repair inspect a ghost even when another normal
    /// window is on the current Space, without treating every overlay as that ghost.
    static func framesDescribeSameSurface(_ candidate: CGRect, _ expected: CGRect) -> Bool {
        guard candidate.width > 0, candidate.height > 0,
              expected.width > 0, expected.height > 0 else { return false }
        let widthRatio = min(candidate.width, expected.width) / max(candidate.width, expected.width)
        let heightRatio = min(candidate.height, expected.height) / max(candidate.height, expected.height)
        guard widthRatio >= 0.5, heightRatio >= 0.5 else { return false }
        let intersection = candidate.intersection(expected)
        guard !intersection.isNull else { return false }
        let overlap = intersection.width * intersection.height
        let smallerArea = min(candidate.width * candidate.height,
                              expected.width * expected.height)
        return overlap / smallerArea >= 0.5
    }

    /// Resolves both parts of the activation request from current WindowServer state.
    static func activationTargetToReach(window: CGWindowID,
                                        pid: pid_t) -> SpaceActivationTarget? {
        let directDestination = spaceToReach(window: window)
        let clickedSpaces = spaces(forWindow: window)

        // A placed window with no destination is already visible. Only an unplaced or
        // retired id is allowed to fall back to another window of the application.
        guard directDestination != nil || clickedSpaces.isEmpty else { return nil }

        let fallbacks: [SpaceActivationTarget] = applicationWindows(pid: pid).compactMap { candidate in
            guard candidate.id != window,
                  candidate.layer == 0,
                  candidate.frame.width >= 200,
                  candidate.frame.height >= 200,
                  let destination = spaceToReach(window: candidate.id)
            else { return nil }
            return SpaceActivationTarget(
                space: destination,
                windowID: candidate.id,
                windowArea: candidate.frame.width * candidate.frame.height
            )
        }
        return preferredActivationTarget(clickedWindowID: window,
                                         directDestination: directDestination,
                                         fallbackCandidates: fallbacks)
    }

    /// Where to go to reach *any* window of an application, for when a particular window
    /// can no longer be found.
    ///
    /// Some applications retire and recreate their windows constantly — measured on Surge
    /// Dashboard, whose 1785x1016 main window vanished and came back under new ids inside
    /// one session, and on WeChat, whose main window the Space SPI reports as belonging
    /// nowhere. A preview card captured a moment earlier can therefore name a window that
    /// the window server no longer places anywhere, and switching to "its" Space is not
    /// possible because it no longer has one.
    ///
    /// Falling back to a sibling window keeps the user going where the application lives
    /// instead of having it activate on whatever desktop happens to be showing.
    static func spaceToReach(applicationWithPID pid: pid_t) -> SpaceID? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            if let destination = spaceToReach(window: id) { return destination }
        }
        return nil
    }

    /// The window server's own view of one application's windows.
    ///
    /// Deliberately not routed through `WindowIndex`: that applies the user's preferences
    /// and drops anything unplaced, which is precisely what a check for unplaced surfaces
    /// has to be able to see.
    struct RawWindow {
        let id: CGWindowID
        let layer: Int
        let isOnScreen: Bool
        let frame: CGRect
    }

    static func applicationWindows(pid: pid_t) -> [RawWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return RawWindow(
                id: id,
                layer: entry[kCGWindowLayer as String] as? Int ?? -1,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
                frame: CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0))
        }
    }

    // MARK: - Desktop symbolic hotkeys
    //
    // "Switch to Desktop N" exists as symbolic hotkey 117+N whether or not the user has
    // bound it in System Settings. Unlike the Mission Control arrow hotkeys — which the
    // WindowServer ignores when posted synthetically — a numbered desktop hotkey fires
    // from a posted event once the hotkey is enabled (measured here: space 4 → 3 via a
    // synthetic ⌃3 with hotkey 120 temporarily enabled). The Dock performs the full
    // native transition, so everything stays consistent and animated.

    private static let _isHotKeyEnabled = resolve(
        "CGSIsSymbolicHotKeyEnabled", as: (@convention(c) (Int32) -> Bool).self)
    private static let _setHotKeyEnabled = resolve(
        "CGSSetSymbolicHotKeyEnabled", as: (@convention(c) (Int32, Bool) -> Int32).self)
    private static let _hotKeyValue = resolve(
        "CGSGetSymbolicHotKeyValue",
        as: (@convention(c) (Int32, UnsafeMutablePointer<unichar>, UnsafeMutablePointer<unichar>,
                             UnsafeMutablePointer<Int32>) -> Int32).self)

    static func desktopHotKeyID(forGlobalDesktop number: Int) -> Int32? {
        // The system defines Desktop 1 through 16.
        guard (1...16).contains(number) else { return nil }
        return Int32(117 + number)
    }

    static func symbolicHotKeyBinding(_ id: Int32) -> (key: CGKeyCode, flags: CGEventFlags)? {
        guard let value = _hotKeyValue else { return nil }
        var equivalent: unichar = 0
        var virtualKey: unichar = 0
        var modifiers: Int32 = 0
        guard value(id, &equivalent, &virtualKey, &modifiers) == 0 else { return nil }
        var flags = CGEventFlags()
        if modifiers & 0x40000 != 0 { flags.insert(.maskControl) }
        if modifiers & 0x80000 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 0x20000 != 0 { flags.insert(.maskShift) }
        if modifiers & 0x100000 != 0 { flags.insert(.maskCommand) }
        return (CGKeyCode(virtualKey), flags)
    }

    static func isSymbolicHotKeyEnabled(_ id: Int32) -> Bool {
        _isHotKeyEnabled?(id) ?? false
    }

    static func setSymbolicHotKey(_ id: Int32, enabled: Bool) {
        _ = _setHotKeyEnabled?(id, enabled)
    }

    /// The number the desktop hotkeys count in: user Spaces across every display in
    /// Mission Control order, main display first.
    static func globalDesktopNumber(of space: SpaceID) -> Int? {
        var number = 0
        for display in managedDisplaySpaces() {
            for entry in display.spaces where entry.type == 0 {
                number += 1
                if entry.id == space { return number }
            }
        }
        return nil
    }

    /// Every Space currently showing, one per display.
    static func currentSpaces() -> Set<SpaceID> {
        var out: Set<SpaceID> = []
        for display in managedDisplaySpaces() {
            if let current = display.currentSpace { out.insert(current.id) }
        }
        return out
    }

    /// Whether a Space is the one currently showing on its display.
    static func isCurrent(space: SpaceID) -> Bool {
        for display in managedDisplaySpaces() where display.currentSpace?.id == space {
            return true
        }
        return false
    }

    /// The Space next to the one a window is on, for "send this window one desktop over".
    ///
    /// Walks the display's own Space order — the Mission Control left-to-right order —
    /// and stops at the ends rather than wrapping, matching how the system's own
    /// "move to next desktop" behaves.
    static func neighbouringSpace(of window: CGWindowID, forward: Bool) -> SpaceID? {
        let current = spaces(forWindow: window)
        guard let home = current.first else { return nil }

        for display in managedDisplaySpaces() {
            let desktops = display.spaces.filter { $0.type == 0 }
            guard let index = desktops.firstIndex(where: { $0.id == home }) else { continue }
            let next = forward ? index + 1 : index - 1
            guard desktops.indices.contains(next) else { return nil }
            return desktops[next].id
        }
        return nil
    }

    /// Moves a window to another Space, and reports whether it actually went.
    ///
    /// The check is not defensive padding. `CGSMoveWindowsToManagedSpace` returns `void`,
    /// and on macOS 26 it silently does nothing to a window this process does not own —
    /// measured against TextEdit, from our own connection and from the owning
    /// application's alike. Reading the membership back is the only way to tell, and
    /// without it every caller is told the move succeeded when nothing happened.
    @discardableResult
    static func move(window: CGWindowID, toSpace space: SpaceID) -> Bool {
        guard let cid = connectionID, let moveWindows = _moveWindowsToManagedSpace else {
            return false
        }
        moveWindows(cid, [NSNumber(value: window)] as CFArray, space)
        return spaces(forWindow: window).contains(space)
    }

    /// The `ManagedSpaceID` for a user-visible desktop number, or nil if there is none.
    static func spaceID(forNumber number: Int) -> SpaceID? {
        for display in managedDisplaySpaces() {
            if let match = display.spaces.first(where: { $0.type == 0 && $0.number == number }) {
                return match.id
            }
        }
        return nil
    }

    /// Every window currently living on the given Space, newest first.
    ///
    /// This is the reliable direction: it sees windows on Spaces the user is not
    /// currently viewing, which `kAXWindowsAttribute` cannot (that attribute is
    /// filtered to the current Space).
    /// Windows registered on a Space.
    ///
    /// `visibleOnly` selects option mask 0x2 instead of 0x7: the smaller set holds only
    /// windows the Space would actually render — measured here, it excludes minimised
    /// windows, windows of a hidden (⌘H) application, and crucially the ghost surfaces
    /// some applications register and never show (WeChat's 280×380 panel, Chrome
    /// Canary's tab-preview strips), which 0x7 reports indistinguishably from real
    /// windows.
    static func windows(onSpace space: SpaceID, visibleOnly: Bool = false) -> [CGWindowID] {
        guard let cid = connectionID, let copy = _copyWindowsWithOptionsAndTags else { return [] }

        // setTags/clearTags are in/out pointers acting as AND-filters. They must be
        // real zeroed variables — passing NULL is not allowed, and passing set=1 with
        // clear=1 returns zero windows.
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaceList = [NSNumber(value: space)] as CFArray

        // Second parameter is a CGSConnectionID, not a pid. Passing 0 means
        // "any owner", which is what we want; passing a pid here returns a
        // plausible-looking but entirely wrong window list.
        guard let result = copy(cid, 0, spaceList, visibleOnly ? 0x2 : 0x7,
                                &setTags, &clearTags)?
            .takeRetainedValue() as? [NSNumber] else { return [] }

        return result.map { CGWindowID($0.uint32Value) }
    }
}
