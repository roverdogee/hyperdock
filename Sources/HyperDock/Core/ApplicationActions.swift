import AppKit
import CoreGraphics

/// Application-level action exposed by the preview bubble's plus button.
@MainActor
enum ApplicationActions {
    static func newWindow(for application: NSRunningApplication) {
        application.activate()

        // Let activation land before sending the conventional New Window shortcut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postKey(keyCode: 45 /* n */, flags: .maskCommand,
                    to: application.processIdentifier)
        }
    }

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
