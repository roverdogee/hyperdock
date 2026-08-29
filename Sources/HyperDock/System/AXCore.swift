import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `_AXUIElementGetWindow` maps an accessibility element to the `CGWindowID` that
/// `CGWindowListCopyWindowInfo` and ScreenCaptureKit speak. It is private but has been
/// exported by HIServices for many releases and is confirmed present on macOS 26.5.2.
///
/// It usefully returns `kAXErrorIllegalArgument` (-25201) with `wid == 0` for Finder's
/// desktop pseudo-window, which doubles as a filter for that junk entry.
///
/// `nonisolated` is required: this project builds with `-default-isolation=MainActor`,
/// which would otherwise place this declaration on the main actor and make it
/// uncallable from the AX queue.
@_silgen_name("_AXUIElementGetWindow")
private nonisolated func _AXUIElementGetWindow(_ element: AXUIElement,
                                               _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Serialised, timeout-bounded access to the Accessibility API.
///
/// **This type exists because of how HyperDock 1.8 died.** Its crash reports show
/// `SIGSEGV` on the main thread inside
/// `AXUIElementCopyAttributeValue → _AXMIGCopyAttributeValue → mach_msg`.
/// That call is a *synchronous MIG RPC*: it blocks the caller until the **target
/// application's** main thread replies, with a 1.5 s default timeout. Issued from your
/// own main thread, a busy or wedged target stalls your entire run loop, and the
/// blocking call re-enters that run loop — which is the reentrancy fault behind the
/// second crash signature, inside `NSWindow _startLiveResize`.
///
/// Two rules follow, and both are enforced here:
///   1. No AX call ever runs on the main thread.
///   2. A process-global messaging timeout is installed at startup.
///
/// A dedicated serial queue rather than an `actor` owns the state, for two reasons: an
/// actor runs on the shared cooperative pool where a slow target application could
/// starve unrelated work, and `AXUIElement` is a non-`Sendable` CFType that must not
/// cross isolation boundaries at all. Elements never leave this queue — callers get
/// immutable value snapshots instead.
///
/// `@unchecked Sendable` is sound under one invariant: **every mutable property is read
/// and written only inside `queue`.**
///
/// The type is `nonisolated` because the project builds with
/// `-default-isolation=MainActor`, which would otherwise put `applicationCache` on the
/// main actor and make it unreachable from the AX queue (SE-0449).
nonisolated final class AXCore: @unchecked Sendable {
    static let shared = AXCore()

    private let queue = DispatchQueue(label: "com.hyperdock.HyperDock.ax", qos: .userInitiated)

    /// Application elements are expensive to recreate and safe to keep. Touched only
    /// on `queue`.
    private var applicationCache: [pid_t: AXUIElement] = [:]
    /// Command-N menu items resolved while a preview is opening. Kept on the AX queue;
    /// caching turns a one-second first traversal into a single action call on click.
    private var newWindowMenuItems: [pid_t: AXUIElement] = [:]
    /// A termination notification normally removes entries; this hard bound also covers
    /// missed notifications and PID churn during sleep/session transitions.
    private let applicationCacheLimit = 128

    /// Window elements resolved by hit testing are remembered so later preview actions
    /// can address the same window directly.
    ///
    /// `kAXWindowsAttribute` is not a reliable index and cannot be treated as one.
    /// Measured on macOS 26.5.2: Sublime Text owns seven windows and advertises **one**
    /// there; WeChat, Surge Dashboard and Chrome Canary omit even their currently focused
    /// window. A pointer hit test and `kAXFocusedWindowAttribute` both hand back the real
    /// element, so keeping it lets raise, close and minimize actions reach windows those
    /// applications omit from their advertised list.
    ///
    /// Touched only on `queue`, like every other stored property here.
    private var windowElements: [CGWindowID: (element: AXUIElement, pid: pid_t)] = [:]

    /// Bounded so a long session cannot accumulate elements for windows that are gone.
    private let windowElementLimit = 64

    private init() {}

    // MARK: - Startup

    /// Installs the process-wide AX messaging timeout.
    ///
    /// Measured: `AXUIElementSetMessagingTimeout` is strictly **per element instance**
    /// and is *not* inherited by children — setting 0.5 s on an application element left
    /// its own child window at 1507 ms. Only the system-wide element sets a real process
    /// default, and that one applies retroactively to elements already created as well
    /// as to new ones. So this single call bounds every request the app ever makes.
    ///
    /// 0.25 s sits well under the 1 s event-tap timeout, so even a wedged target cannot
    /// cascade into the input system.
    nonisolated static func installGlobalTimeout(_ seconds: Float = 0.25) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// Whether this process currently holds Accessibility permission.
    ///
    /// Note: merely calling this from a bundled app creates a TCC row for our bundle id,
    /// denied if the user has not granted it. That is why the bundle id is fixed forever.
    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt offering to open Privacy & Security.
    @discardableResult
    nonisolated static func requestTrust() -> Bool {
        // The SDK exposes kAXTrustedCheckOptionPrompt as a mutable global, which Swift 6
        // rejects as shared mutable state. Its value is a stable, documented constant.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Queue plumbing

    /// Runs `body` on the AX queue and resumes with its result.
    private nonisolated func perform<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// CoreFoundation bridges every CF object to every opaque AX reference at compile
    /// time, so `as?` cannot validate an attribute's runtime type. Check the type ID
    /// before converting instead; malformed or application-specific AX attributes then
    /// fail the operation rather than crashing the process with `as!`.
    nonisolated static func checkedValue(_ raw: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXValue.self)
    }

    nonisolated static func checkedElement(_ raw: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    /// The application element for a pid. Must be called on `queue`.
    private nonisolated func cachedApplication(_ pid: pid_t) -> AXUIElement {
        dispatchPrecondition(condition: .onQueue(queue))
        if let cached = applicationCache[pid] { return cached }
        if applicationCache.count >= applicationCacheLimit {
            applicationCache.removeAll(keepingCapacity: true)
        }
        let created = AXUIElementCreateApplication(pid)
        applicationCache[pid] = created
        return created
    }

    /// Drops a terminated application's cached element.
    nonisolated func forget(pid: pid_t) {
        queue.async {
            self.applicationCache.removeValue(forKey: pid)
            self.newWindowMenuItems.removeValue(forKey: pid)
            self.windowElements = self.windowElements.filter { $0.value.pid != pid }
        }
    }

    /// Remembers a window element found by a reliable route. Must be called on `queue`.
    private nonisolated func remember(_ element: AXUIElement, id: CGWindowID, pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard id != 0 else { return }
        if windowElements.count >= windowElementLimit, windowElements[id] == nil {
            // Cheapest possible eviction, and the contents are a cache either way: a
            // dropped entry costs one fall back to the window list, nothing more.
            windowElements.removeAll(keepingCapacity: true)
        }
        windowElements[id] = (element, pid)
    }

    // MARK: - Dock introspection

    /// A single Dock tile, captured as plain values.
    nonisolated struct DockTile: Sendable, Equatable {
        let title: String
        let subrole: String
        /// Global, **top-left origin** coordinates, as AX reports them.
        let frame: CGRect
        let bundleURL: URL?
        let isRunning: Bool

        /// Subrole is the authoritative discriminator between application tiles,
        /// separators, the Trash, folders and minimised-window tiles.
        var isApplication: Bool { subrole == "AXApplicationDockItem" }
    }

    /// Reads every Dock tile.
    ///
    /// The Dock's own `CGWindow` bounds is the whole display, not the Dock strip, so
    /// geometry can only come from this AX tree. Usefully, AX keeps reporting tile
    /// frames while the Dock is hidden and updates them live during the slide-in
    /// animation — which is what keeps the bubble's pointer aimed at a moving icon.
    ///
    /// Tile positions shift with magnification, tile size, orientation and Dock
    /// repopulation, so this is called fresh on every hover rather than cached.
    /// Presses "Desktop N" in Mission Control's Spaces Bar.
    ///
    /// Only meaningful while Mission Control is presented — the buttons exist in the
    /// Dock's accessibility tree only then. This is the one Dock-managed way to reach a
    /// desktop that activation follow cannot serve. Titles are reported in English
    /// ("Desktop 3") even on a Chinese-language system, measured here on macOS 26.
    ///
    /// `displayFrame` (top-left-origin coordinates) disambiguates same-numbered desktops
    /// on different displays; nil accepts the first title match.
    func pressMissionControlDesktopButton(number: Int, within displayFrame: CGRect?) async -> Bool {
        await perform {
            guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first
            else { return false }
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            let wanted = "Desktop \(number)"

            var stack: [(AXUIElement, Int)] = [(app, 0)]
            while let (element, depth) = stack.popLast() {
                if depth <= 8,
                   let children = Self.value(element, kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children { stack.append((child, depth + 1)) }
                }
                guard Self.value(element, kAXRoleAttribute) as? String == "AXButton",
                      Self.value(element, kAXTitleAttribute) as? String == wanted
                else { continue }

                if let displayFrame {
                    var origin = CGPoint.zero
                    if let raw = Self.value(element, kAXPositionAttribute),
                       let value = Self.checkedValue(raw) {
                        AXValueGetValue(value, .cgPoint, &origin)
                    }
                    // The bar hangs partly above the screen edge while collapsed, so
                    // only the x axis is meaningful for "which display".
                    guard origin.x >= displayFrame.minX, origin.x < displayFrame.maxX
                    else { continue }
                }
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            return false
        }
    }

    /// Invokes the target application's Command-N menu item without activating it.
    ///
    /// Posting Command-N after `NSRunningApplication.activate()` made the new window
    /// reliable, but it also stole focus and caused the preview to disappear. Accessibility
    /// can invoke the menu item's action directly while its application stays in the
    /// background. Matching the shortcut metadata instead of the title keeps this working
    /// in every application language.
    func pressNewWindowMenuItem(pid: pid_t) async -> Bool {
        await perform {
            if let cached = self.newWindowMenuItems[pid] {
                let result = AXUIElementPerformAction(cached, kAXPressAction as CFString)
                if result == .success { return true }
                self.newWindowMenuItems.removeValue(forKey: pid)
            }
            guard let element = self.resolveNewWindowMenuItem(pid: pid) else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }

    /// Starts the expensive menu traversal while the pointer is still looking at the
    /// preview, before it can click the plus button.
    func prepareNewWindowMenuItem(pid: pid_t) async {
        await perform {
            guard self.newWindowMenuItems[pid] == nil else { return }
            _ = self.resolveNewWindowMenuItem(pid: pid)
        }
    }

    /// Must run on `queue`; the returned element never crosses that queue boundary.
    private func resolveNewWindowMenuItem(pid: pid_t) -> AXUIElement? {
        dispatchPrecondition(condition: .onQueue(queue))
        let app = cachedApplication(pid)
        guard let rawMenuBar = Self.value(app, kAXMenuBarAttribute),
              let menuBar = Self.checkedElement(rawMenuBar)
        else { return nil }

        var stack: [(AXUIElement, Int)] = [(menuBar, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 400 {
            visited += 1
            if depth <= 6,
               let children = Self.value(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { stack.append((child, depth + 1)) }
            }

            let virtualKey = (Self.value(element, kAXMenuItemCmdVirtualKeyAttribute)
                as? NSNumber)?.intValue
            let commandCharacter = (Self.value(element, kAXMenuItemCmdCharAttribute)
                as? String)?.lowercased()
            let modifiers = (Self.value(element, kAXMenuItemCmdModifiersAttribute)
                as? NSNumber)?.uint32Value ?? 0
            guard (virtualKey == 45 || commandCharacter == "n"), modifiers == 0
            else { continue }

            if let enabled = Self.value(element, kAXEnabledAttribute) as? Bool, !enabled {
                continue
            }
            if newWindowMenuItems.count >= applicationCacheLimit {
                newWindowMenuItems.removeAll(keepingCapacity: true)
            }
            newWindowMenuItems[pid] = element
            return element
        }
        return nil
    }

    /// Changes the frontmost application through Accessibility. This is synchronous at
    /// the window server, unlike `NSRunningApplication.activate()`, whose request may be
    /// ignored or arrive after a later focus restoration.
    func setFrontmost(pid: pid_t) async -> Bool {
        await perform {
            AXUIElementSetAttributeValue(
                self.cachedApplication(pid),
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            ) == .success
        }
    }

    /// Captures the target application's currently focused window as a stable CG id so
    /// it can be restored after a temporarily frontmost background action.
    func focusedWindowID(pid: pid_t) async -> CGWindowID? {
        await perform {
            let app = self.cachedApplication(pid)
            guard let raw = Self.value(app, kAXFocusedWindowAttribute),
                  let element = Self.checkedElement(raw)
            else { return nil }
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
            self.remember(element, id: id, pid: pid)
            return id
        }
    }

    func dockTiles() async -> [DockTile] {
        await perform {
            guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first
            else { return [] }

            let app = AXUIElementCreateApplication(dock.processIdentifier)

            // The application element has exactly one child: a horizontal AXList whose
            // children are the tiles.
            guard let children = Self.value(app, kAXChildrenAttribute) as? [AXUIElement],
                  let list = children.first(where: {
                      Self.value($0, kAXRoleAttribute) as? String == "AXList"
                  }),
                  let tiles = Self.value(list, kAXChildrenAttribute) as? [AXUIElement]
            else { return [] }

            return tiles.compactMap { tile -> DockTile? in
                guard let subrole = Self.value(tile, kAXSubroleAttribute) as? String else {
                    return nil
                }
                var origin = CGPoint.zero
                var size = CGSize.zero
                if let raw = Self.value(tile, kAXPositionAttribute),
                   let value = Self.checkedValue(raw) {
                    AXValueGetValue(value, .cgPoint, &origin)
                }
                if let raw = Self.value(tile, kAXSizeAttribute),
                   let value = Self.checkedValue(raw) {
                    AXValueGetValue(value, .cgSize, &size)
                }
                return DockTile(
                    title: Self.value(tile, kAXTitleAttribute) as? String ?? "",
                    subrole: subrole,
                    frame: CGRect(origin: origin, size: size),
                    bundleURL: Self.value(tile, kAXURLAttribute) as? URL,
                    isRunning: Self.value(tile, "AXIsApplicationRunning") as? Bool ?? false
                )
            }
        }
    }

    // MARK: - Window control

    /// Brings a window forward and activates its application.
    ///
    /// `kAXFocusedAttribute` proved non-settable on every window tested, so focus is
    /// established with `AXRaise` plus an explicit activation rather than by setting
    /// that attribute. Crossing to the window's Space happens implicitly.
    /// Brings a window forward, retrying while its Space finishes switching.
    ///
    /// `kAXWindowsAttribute` is filtered to the current Space, so a window that lives
    /// elsewhere has no reachable element *until the display is showing that Space*.
    /// Callers switch the Space first; this then polls briefly because the switch is
    /// animated and the window does not become enumerable the instant it is requested.
    @discardableResult
    /// Marks a window as its application's main window, without raising anything.
    ///
    /// Exists for the space-switch path: when an application is activated, the Dock
    /// switches to the Space holding the application's *main* window. Designating the
    /// clicked window first is what points that mechanism at the right desktop.
    func designateMain(window id: CGWindowID, pid: pid_t) async -> Bool {
        await perform {
            guard let element = self.findWindow(id: id, pid: pid) else { return false }
            return AXUIElementSetAttributeValue(
                element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
        }
    }

    func raise(window id: CGWindowID, pid: pid_t, attempts: Int = 12,
               fallbackActivate: Bool = true) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            let raised = await perform {
                guard let element = self.findWindow(id: id, pid: pid) else { return false }
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                             kCFBooleanFalse)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)

                // Bring the owning application forward through Accessibility rather than
                // `NSRunningApplication.activate`. Since macOS 14, activation is
                // cooperative: a background agent that is not itself frontmost has its
                // activate() request ignored, so the window would rise within its app
                // while the app stayed behind — measured here as `raised=true` with the
                // frontmost application never changing. Setting AXFrontmost is the
                // supported route for an accessibility client and is not subject to that
                // rule.
                let app = self.cachedApplication(pid)
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString,
                                             kCFBooleanTrue)
                return true
            }
            if raised {

                // Deliberately NOT calling NSRunningApplication.activate here.
                //
                // Setting AXFrontmost above already brings the application forward, and
                // it does so synchronously — measured as frontmost on the very first
                // poll. Adding activate() on top made the app come forward and then lose
                // focus again a moment later: the request is delivered asynchronously and
                // lands after the AX activation has settled, which the WindowServer
                // resolves by handing focus back to whatever was frontmost before.
                // Traced as `raise ok: found@0 frontAfter=0` immediately followed by the
                // previous application being frontmost again two seconds later.

                // Confirm it actually came forward. The first activation after launch
                // sometimes does not take — the AX connection to that application is
                // still warming up — so verify and ask once more rather than reporting
                // success on a window the user never saw.
                // Confirm the application really stayed forward, and re-assert if not.
                //
                // Becoming frontmost once is not enough. Our own preview panel is
                // key-capable — it has to be, or clicks never reach its content — and
                // when a key-capable window is ordered out AppKit reassigns key status,
                // which can hand focus straight back to the application that had it
                // before. That undoes the raise a beat after it succeeded, so a single
                // early check reports success for a window the user never sees.
                //
                // Hence: check, wait past the window in which the hand-back happens,
                // check again, and only then assert a second time if needed.
                for round in 0..<3 {
                    for _ in 0..<5 {
                        try? await Task.sleep(for: .milliseconds(40))
                        let frontmost = await MainActor.run {
                            NSWorkspace.shared.frontmostApplication?.processIdentifier
                        }
                        if frontmost == pid { break }
                    }

                    // Settle, then verify it *stuck* rather than merely happened.
                    try? await Task.sleep(for: .milliseconds(120))
                    let settled = await MainActor.run {
                        NSWorkspace.shared.frontmostApplication?.processIdentifier
                    }
                    if settled == pid {
                        if round > 0 {
                            Log.windows.debug("raise: frontmost re-asserted after \(round) retries")
                        }
                        return true
                    }

                    await perform {
                        let element = self.cachedApplication(pid)
                        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString,
                                                     kCFBooleanTrue)
                    }
                }

                let front = await MainActor.run {
                    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                }
                Log.windows.error("raise: \(id) raised but front stayed \(front, privacy: .public)")
                await perform {
                    _ = AXUIElementSetAttributeValue(self.cachedApplication(pid),
                                                     kAXFrontmostAttribute as CFString,
                                                     kCFBooleanTrue)
                }
                return true
            }
            // ~60 ms per attempt: a Space switch animates for roughly a third of a second.
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(60))
            }
        }

        // The window never became reachable — most likely it is on a Space we could not
        // switch to. Activating the application is the last approximation, but only when
        // the caller has nothing better: an activation can land on the wrong desktop
        // (some applications answer it by putting a window on whichever desktop is
        // showing), so a caller that can instead go to a *real* sibling window passes
        // false and orchestrates that itself.
        Log.windows.error("raise: window \(id) never became reachable after \(attempts) attempts")
        guard fallbackActivate else { return false }
        await MainActor.run {
            // Plain activation, deliberately not `.activateAllWindows`.
            //
            // That option orders *every* window of the application forward, and several
            // applications keep windows the window server places on no Space at all —
            // measured on Surge Dashboard, five of its six windows. Dragging those to the
            // front leaves the app's window list in a state Mission Control then shows and
            // cannot act on. Bringing the application forward is all this fallback ever
            // meant; which of its windows ends up in front is the application's business.
            _ = NSRunningApplication(processIdentifier: pid)?.activate()
        }
        return false
    }

    /// Presses a window's close button.
    /// Presses a window's close button, retrying while its Space settles.
    ///
    /// Like ``raise(window:pid:attempts:)``, this has to poll: `kAXWindowsAttribute` is
    /// filtered to the current Space, so a window living elsewhere has no reachable
    /// element until its Space is showing. Closing was originally written without that
    /// retry — the cross-Space fix was applied to raising and not here — so the close
    /// button silently did nothing for exactly the off-Space windows this app exists to
    /// surface.
    @discardableResult
    func close(window id: CGWindowID, pid: pid_t, attempts: Int = 12) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            let closed = await perform {
                guard let element = self.findWindow(id: id, pid: pid),
                      let rawButton = Self.value(element, kAXCloseButtonAttribute),
                      let button = Self.checkedElement(rawButton)
                else { return false }
                return AXUIElementPerformAction(button,
                                                kAXPressAction as CFString) == .success
            }
            if closed { return true }

            // Unhide the application once, in case the window is merely hidden rather
            // than genuinely unreachable.
            if attempt == 0 {
                await unhideApplication(pid: pid)
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        Log.windows.error("could not close window \(id)")
        return false
    }

    /// The window ids this application still vends to Accessibility.
    ///
    /// Exists to tell a *minimised* window from a *destroyed* one, which
    /// `CGWindowListCopyWindowInfo` cannot: measured on TextEdit, a closed document window
    /// stays in the `.optionAll` listing indefinitely, keeping its title, bounds, alpha,
    /// sharing state and store type — every field identical to a minimised window's, with
    /// only `kCGWindowIsOnscreen` absent, exactly as when minimised. Accessibility does
    /// draw the distinction: a minimised window is still listed (carrying
    /// `kAXMinimizedAttribute`), a closed one is gone within a frame.
    ///
    /// Returns `nil` when the list cannot be read at all — a caller should then trust
    /// CGWindowList rather than discard windows on the strength of a failed query.
    /// `kAXWindowsAttribute` is filtered to the current Space, so only ever narrow
    /// windows already believed to be *on* the current Space with this.
    func liveWindowIDs(pid: pid_t) async -> Set<CGWindowID>? {
        await perform {
            let app = self.cachedApplication(pid)
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
            guard error == .success, let windows = raw as? [AXUIElement] else { return nil }
            var ids: Set<CGWindowID> = []
            for window in windows {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(window, &id) == .success { ids.insert(id) }
            }
            return ids
        }
    }

    /// Unhides the owning application, which is the one recoverable case.
    ///
    /// Note what this deliberately does *not* attempt. Some windows a preview can show
    /// are unreachable through Accessibility entirely: measured on Ghostty, CGWindowList
    /// reported six windows while `kAXWindowsAttribute` listed one, and the missing five
    /// appeared nowhere else either — not under a different attribute, and not as
    /// minimised tiles in the Dock, whose only subroles are application, separator and
    /// trash. Those are an application's own off-screen surfaces (background terminal
    /// tabs and the like), which it never vends to Accessibility. Closing them is not
    /// possible by this route, so `close` reports failure rather than pretending.
    private func unhideApplication(pid: pid_t) async {
        await perform {
            _ = AXUIElementSetAttributeValue(self.cachedApplication(pid),
                                             kAXHiddenAttribute as CFString, kCFBooleanFalse)
        }
    }

    /// Minimises or restores a window.
    /// Minimises or restores a window, retrying while the window server is busy.
    ///
    /// The retry is what makes "restore all windows" restore more than one of them.
    /// Un-minimising plays the genie animation, and a write aimed at a second window
    /// while the first is still animating comes back `cannotComplete`. Without a retry
    /// that window is simply left minimised, silently — measured on two minimised
    /// TextEdit windows, where only the first ever came back.
    @discardableResult
    func setMinimized(_ minimized: Bool, window id: CGWindowID, pid: pid_t,
                      attempts: Int = 8) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            let result = await perform { () -> AXError in
                guard let element = self.findWindow(id: id, pid: pid) else { return .invalidUIElement }
                // Settability varies per window — a utility panel reported AXMinimized as
                // non-settable — so ask before setting rather than assuming.
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable)
                guard settable.boolValue else { return .attributeUnsupported }
                return AXUIElementSetAttributeValue(element,
                                                    kAXMinimizedAttribute as CFString,
                                                    minimized ? kCFBooleanTrue : kCFBooleanFalse)
            }
            if result == .success { return true }
            // A window that cannot carry the attribute at all will not start doing so.
            if result == .attributeUnsupported { return false }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        Log.windows.error("could not set minimized=\(minimized) on window \(id)")
        return false
    }

    // MARK: - Internals

    /// Finds the `AXUIElement` for a `CGWindowID`. Must be called on `queue`.
    ///
    /// `kAXWindowsAttribute` is filtered to the *current* Space — it returns success
    /// with an empty array for an application whose windows all live elsewhere — so this
    /// resolves to `nil` for off-Space windows, and every caller treats that as "cannot
    /// control this one right now".
    /// Resolves a window by hit-testing the middle of where the window server says it is.
    ///
    /// The fallback for when `kAXWindowsAttribute` does not list a window that plainly
    /// exists — measured on several applications, including ones that omit even their
    /// focused window. A hit test asks the system what is actually at a point, so it does
    /// not depend on the application volunteering an inventory. Only usable once the
    /// window is genuinely on screen, which after a Space switch it is.
    ///
    /// The returned element is verified to carry the id we asked for: a hit test finds
    /// whatever is topmost, which is the wrong window if something overlaps it.
    /// Must be called on `queue`.
    private nonisolated func resolveByHitTest(id: CGWindowID, pid: pid_t) -> AXUIElement? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]],
              let entry = raw.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }),
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }

        let centre = CGPoint(x: (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2,
                             y: (bounds["Y"] ?? 0) + (bounds["Height"] ?? 0) / 2)
        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(centre.x), Float(centre.y),
                                               &hit) == .success,
              var element = hit else { return nil }

        var depth = 0
        while depth < 12, Self.value(element, kAXRoleAttribute) as? String != kAXWindowRole {
            guard let parent = Self.value(element, kAXParentAttribute),
                  let parentElement = Self.checkedElement(parent) else { return nil }
            element = parentElement
            depth += 1
        }
        var found: CGWindowID = 0
        guard Self.value(element, kAXRoleAttribute) as? String == kAXWindowRole,
              _AXUIElementGetWindow(element, &found) == .success, found == id
        else { return nil }

        remember(element, id: id, pid: pid)
        return element
    }

    private nonisolated func findWindow(id: CGWindowID, pid: pid_t) -> AXUIElement? {
        // A remembered element first — see `windowElements` for why the list below cannot
        // be relied on. Re-reading the id off the element confirms it is still the window
        // it was: a dead element answers with an error, and the window server reuses ids.
        if let cached = windowElements[id], cached.pid == pid {
            var found: CGWindowID = 0
            if _AXUIElementGetWindow(cached.element, &found) == .success, found == id {
                return cached.element
            }
            windowElements[id] = nil
        }

        let app = cachedApplication(pid)
        let listed = (Self.value(app, kAXWindowsAttribute) as? [AXUIElement])?
            .first { candidate in
                var found: CGWindowID = 0
                return _AXUIElementGetWindow(candidate, &found) == .success && found == id
            }
        // The list is not an index that can be trusted, so a miss is not an answer.
        return listed ?? resolveByHitTest(id: id, pid: pid)
    }

    /// The single choke point for reading an attribute. Returns `nil` on any error,
    /// including `kAXErrorCannotComplete` (-25204), which is what a timeout looks like.
    private nonisolated static func value(_ element: AXUIElement,
                                          _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }
}
