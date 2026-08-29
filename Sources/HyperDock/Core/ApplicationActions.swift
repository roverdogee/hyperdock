import AppKit
import CoreGraphics

/// Application-level action exposed by the preview bubble's plus button.
@MainActor
enum ApplicationActions {
    static func newWindow(for application: NSRunningApplication) async -> Bool {
        guard !application.isTerminated else { return false }
        let pid = application.processIdentifier
        let existing = Set(
            CGS.applicationWindows(pid: pid)
                .filter { $0.layer == 0 }
                .map(\.id)
        )
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousTargetWindow = await AXCore.shared.focusedWindowID(pid: pid)

        if await AXCore.shared.pressNewWindowMenuItem(pid: pid) {
            if await waitForNewWindow(pid: pid, excluding: existing, attempts: 40) != nil {
                Log.dock.debug("background new-window menu succeeded for pid \(pid, privacy: .public)")
                return true
            }
            Log.dock.debug("background new-window menu was accepted without creating a window for pid \(pid, privacy: .public)")
        }

        // Some applications acknowledge a background AX menu press but silently discard
        // its command. Briefly make the target frontmost, deliver Command-N, then restore
        // both the previous application and the target's previous focused window. The
        // preview controller suppresses these internal activation notifications, so the
        // user remains in the same interaction.
        guard await AXCore.shared.setFrontmost(pid: pid) else { return false }
        await waitUntilFrontmost(pid: pid)
        guard postKey(keyCode: 45 /* n */, flags: .maskCommand, to: pid) else {
            await restoreFocus(previousApplication: previousApplication,
                               targetPID: pid,
                               previousTargetWindow: previousTargetWindow)
            return false
        }

        let created = await waitForNewWindow(pid: pid, excluding: existing, attempts: 28) != nil
        await restoreFocus(previousApplication: previousApplication,
                           targetPID: pid,
                           previousTargetWindow: previousTargetWindow)
        Log.dock.debug("foreground fallback new-window result=\(created, privacy: .public) for pid \(pid, privacy: .public)")
        return created
    }

    private static func waitForNewWindow(pid: pid_t,
                                         excluding existing: Set<CGWindowID>,
                                         attempts: Int) async -> CGWindowID? {
        var previousCandidate: CGWindowID?
        for _ in 0..<attempts {
            if let created = CGS.applicationWindows(pid: pid).first(where: {
                $0.layer == 0
                    && $0.frame.width >= 80
                    && $0.frame.height >= 60
                    && !existing.contains($0.id)
            }) {
                // Ignore short-lived layer-zero surfaces created while an app processes
                // its menu command. A real window must survive two consecutive polls.
                if previousCandidate == created.id { return created.id }
                previousCandidate = created.id
            } else {
                previousCandidate = nil
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private static func waitUntilFrontmost(pid: pid_t) async {
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func restoreFocus(previousApplication: NSRunningApplication?,
                                     targetPID: pid_t,
                                     previousTargetWindow: CGWindowID?) async {
        if let previousTargetWindow {
            _ = await AXCore.shared.designateMain(window: previousTargetWindow, pid: targetPID)
        }

        if let previousApplication,
           !previousApplication.isTerminated,
           previousApplication.processIdentifier != targetPID {
            _ = await AXCore.shared.setFrontmost(pid: previousApplication.processIdentifier)
        } else if let previousTargetWindow {
            _ = await AXCore.shared.raise(
                window: previousTargetWindow,
                pid: targetPID,
                attempts: 1,
                fallbackActivate: false
            )
        }
    }

    private static func postKey(keyCode: CGKeyCode,
                                flags: CGEventFlags,
                                to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        guard let down, let up else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
