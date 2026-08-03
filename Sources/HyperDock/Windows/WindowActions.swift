import AppKit
import CoreGraphics

/// Actions that act on an application rather than a specific window.
@MainActor
enum WindowActions {

    /// Asks an application to open a new window.
    ///
    /// Sent as a synthetic ⌘N to the target rather than driven through its File menu:
    /// menu structure and item titles vary per application and per language, whereas
    /// ⌘N is near-universal for this.
    static func newWindow(for application: NSRunningApplication) {
        // Only frontmost-ness is needed for the ⌘N below; gathering every window would be
        // a side effect nobody asked for.
        application.activate()

        // A short hop lets activation land first; a key event sent to an application
        // that is not yet frontmost is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postKey(keyCode: 45 /* n */, flags: .maskCommand, to: application.processIdentifier)
        }
    }

    static func quit(_ application: NSRunningApplication) {
        application.terminate()
    }

    static func hide(_ application: NSRunningApplication) {
        application.hide()
    }

    /// Unhides the application, brings it forward and restores its minimised windows.
    ///
    /// Plain activation is deliberate. `.activateAllWindows` also orders surfaces that
    /// belong to no Space; Surge is one application that keeps several, and ordering them
    /// creates windows visible on the desktop but absent from Mission Control.
    static func showAllWindows(_ application: NSRunningApplication) {
        application.unhide()
        application.activate()

        let pid = application.processIdentifier
        Task {
            let windows = await WindowIndex.shared.windows(
                forPID: pid, preferences: WindowQueryOptions.current())
            for window in windows where window.isMinimized {
                await AXCore.shared.setMinimized(false, window: window.id, pid: pid)
            }
        }
    }

    /// Minimises every window the application owns on the current Space.
    static func minimizeAllWindows(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        Task {
            let windows = await WindowIndex.shared.windows(
                forPID: pid, preferences: WindowQueryOptions.current())
            for window in windows where !window.isMinimized {
                await AXCore.shared.setMinimized(true, window: window.id, pid: pid)
            }
        }
    }

    /// Arranges every on-screen window this application has on the current Space into a
    /// grid filling the screen they are already on.
    ///
    /// Only windows that are actually on screen take part: a minimised or off-Space window
    /// has no place in a layout of what is in front of you, and moving it would silently
    /// un-minimise it.
    static func tileWindows(of application: NSRunningApplication) {
        let pid = application.processIdentifier
        Task {
            let preferences = WindowQueryOptions.current()
            let windows = await WindowIndex.shared.windows(forPID: pid, preferences: preferences)
                .filter { $0.isOnScreen && $0.isOnCurrentSpace }
            guard !windows.isEmpty else { return }

            // Everything that touches `NSScreen` happens in one hop and hands back only
            // rectangles: `NSScreen` is not `Sendable` and must not cross out of here.
            //
            // The screen is the one holding the first window, so a set already gathered on
            // one display is tiled there rather than jumping to wherever the pointer is.
            let count = windows.count
            let first = windows[0].frame
            let cells: [CGRect] = await MainActor.run {
                let anchor = ScreenGeometry.appKitPoint(
                    fromAccessibility: CGPoint(x: first.midX, y: first.midY))
                guard let screen = ScreenGeometry.screen(containing: anchor) else { return [] }
                let preferences = Preferences.shared
                return WindowGrid.frames(count: count,
                                         in: screen.visibleFrame,
                                         fixedColumns: preferences.tileGridColumns,
                                         fixedRows: preferences.tileGridRows,
                                         gap: CGFloat(preferences.tileGridGap))
            }
            guard !cells.isEmpty else { return }

            for (window, cell) in zip(windows, cells) {
                let target = ScreenGeometry.accessibilityRect(fromAppKit: cell)
                await AXCore.shared.setFrame(target, window: window.id, pid: pid)
            }
        }
    }

    static func relaunch(_ application: NSRunningApplication) {
        guard let url = application.bundleURL else { return }
        application.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Runs the action a Dock shortcut is bound to.
    static func perform(_ action: DockAction, on application: NSRunningApplication) {
        switch action {
        case .quitApp: quit(application)
        case .hideApp: hide(application)
        case .newWindow: newWindow(for: application)
        case .showAllWindows: showAllWindows(application)
        case .minimizeAllWindows: minimizeAllWindows(application)
        case .relaunchApp: relaunch(application)
        }
    }

    // MARK: - Key synthesis

    private static func postKey(keyCode: CGKeyCode,
                                flags: CGEventFlags,
                                to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags

        down?.postToPid(pid)
        up?.postToPid(pid)
    }
}
