import AppKit
import SwiftUI

/// The translucent rectangle that previews where a window will land.
///
/// Deliberately not interactive: it never accepts mouse events, because it appears
/// underneath a pointer that is mid-drag and must not intercept anything.
@MainActor
final class SnapOverlay {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above ordinary windows but below the preview bubble, so the two never fight.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        let view = NSHostingView(rootView: SnapOverlayView())
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    /// Shows the preview at `frame`, given in AppKit coordinates.
    func show(at frame: CGRect) {
        guard frame != panel.frame || !panel.isVisible else { return }
        if panel.isVisible {
            // Animate between zones so sliding along an edge reads as one continuous
            // gesture rather than the rectangle teleporting.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
}

private struct SnapOverlayView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.tint.opacity(0.22))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint.opacity(0.75), lineWidth: 2)
            }
            .padding(3)
    }
}
