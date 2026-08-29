import AppKit
import CoreGraphics

/// Converts between the two coordinate systems this app has to live in.
///
/// Accessibility and `CGWindowListCopyWindowInfo` report a **top-left** origin with y
/// growing downward. AppKit's `NSScreen`, `NSWindow.setFrameOrigin` and
/// `NSEvent.mouseLocation` use a **bottom-left** origin with y growing upward.
///
/// Both systems are anchored to the *primary* display — CoreGraphics to its top-left
/// corner, AppKit to its bottom-left — so the flip mirrors around the primary display's
/// height and nothing else.
///
/// It is tempting to mirror around the top of the whole desktop instead, and that is
/// wrong as soon as a secondary display sits higher than the primary one. Verified here
/// with a 2560×1440 primary and a 1728×1117 secondary placed at y = 360: the union's
/// top is 1477, but the pointer reported AppKit y = 980.7 against CoreGraphics y = 459.3,
/// and 980.7 + 459.3 = 1440.0 exactly — the primary display's height. Using 1477 offset
/// every conversion by 37 pt, which is enough to make Dock hit-testing miss entirely.
nonisolated enum ScreenGeometry {

    /// The y coordinate every conversion mirrors around: the height of the display that
    /// sits at AppKit's origin.
    static var primaryHeight: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 0
    }

    /// Top-left origin point to AppKit's bottom-left origin.
    static func appKitPoint(fromAccessibility point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Top-left origin rect to an AppKit rect, mirroring the whole box so the returned
    /// origin is the *bottom* left corner AppKit expects.
    static func appKitRect(fromAccessibility rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// AppKit rect back to top-left origin, for handing a frame to Accessibility.
    static func accessibilityRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The screen containing a point given in AppKit coordinates.
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    static func dockEdge(forDockFrame frame: CGRect) -> DockEdge {
        guard frame.width > 0, frame.height > 0 else { return .bottom }
        if frame.width > frame.height { return .bottom }

        let midX = frame.midX
        let screenMidX = (screen(containing: appKitPoint(fromAccessibility: CGPoint(x: midX, y: frame.midY)))
            ?? NSScreen.main)?.frame.midX ?? midX
        return midX < screenMidX ? .left : .right
    }
}
