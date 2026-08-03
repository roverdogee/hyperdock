import AppKit

/// Where a window lands when dragged to a screen edge or driven by a keyboard shortcut.
enum SnapZone: Sendable, Equatable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize
    case centre

    /// Which way a pure edge zone travels, for walking a window across displays.
    /// Quarters, centre and maximize express placement, not motion, so they never cross.
    enum Direction { case left, right, up, down }

    var cardinalDirection: Direction? {
        switch self {
        case .left: return .left
        case .right: return .right
        case .top: return .up
        case .bottom: return .down
        default: return nil
        }
    }

    /// Where a window lands after crossing to the neighbouring display: the motion
    /// continues, so leaving through the right edge enters the next display's *left*
    /// half — pressing the same key repeatedly walks the window across the desktop in
    /// half-screen steps, which is how Magnet and Rectangle behave.
    var continuationZone: SnapZone {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        default: return self
        }
    }

    /// The frame this zone occupies, in AppKit (bottom-left origin) coordinates.
    ///
    /// Computed against `visibleFrame` rather than `frame` so the menu bar and, when it
    /// is not set to auto-hide, the Dock are excluded. Note that with auto-hide on,
    /// `visibleFrame` reserves nothing for the Dock — measured here as identical to
    /// `frame` — which is correct: a hidden Dock should not cost a window any space.
    func frame(in screen: NSScreen) -> CGRect {
        let area = screen.visibleFrame
        let halfWidth = area.width / 2
        let halfHeight = area.height / 2

        switch self {
        case .left:
            return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height)
        case .right:
            return CGRect(x: area.midX, y: area.minY, width: halfWidth, height: area.height)
        case .top:
            return CGRect(x: area.minX, y: area.midY, width: area.width, height: halfHeight)
        case .bottom:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: halfHeight)
        case .topLeft:
            return CGRect(x: area.minX, y: area.midY, width: halfWidth, height: halfHeight)
        case .topRight:
            return CGRect(x: area.midX, y: area.midY, width: halfWidth, height: halfHeight)
        case .bottomLeft:
            return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: halfHeight)
        case .bottomRight:
            return CGRect(x: area.midX, y: area.minY, width: halfWidth, height: halfHeight)
        case .maximize:
            return area
        case .centre:
            return CGRect(x: area.minX + area.width * 0.15,
                          y: area.minY + area.height * 0.15,
                          width: area.width * 0.7,
                          height: area.height * 0.7)
        }
    }

    /// The zone a pointer at `point` implies, or `nil` when it is not near an edge.
    ///
    /// Corners take priority over edges, so dragging into the very corner quarters the
    /// window rather than halving it.
    static func zone(forPointerAt point: CGPoint, in screen: NSScreen) -> SnapZone? {
        let area = screen.frame
        // The band has to be *hittable*. At 8 pt it measured as a target you had to land
        // inside almost exactly — 5 pt from the edge snapped, 10 pt did not — which is
        // most of why dragging to an edge felt like it did not work.
        //
        // A generous band is safe here in a way it would not be for a plain drag: this
        // only runs while the move modifiers are held, so every drag that reaches it is
        // deliberate. Passing near an edge on the way somewhere else is handled by the
        // dwell in `requiredDelay`, not by keeping the target small.
        let edge: CGFloat = 32
        let corner: CGFloat = 120

        let nearLeft = point.x <= area.minX + edge
        let nearRight = point.x >= area.maxX - edge
        let nearBottom = point.y <= area.minY + edge
        let nearTop = point.y >= area.maxY - edge

        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }

        let inLeftCorner = point.x <= area.minX + corner
        let inRightCorner = point.x >= area.maxX - corner
        let inTopCorner = point.y >= area.maxY - corner
        let inBottomCorner = point.y <= area.minY + corner

        if nearLeft && inTopCorner { return .topLeft }
        if nearLeft && inBottomCorner { return .bottomLeft }
        if nearRight && inTopCorner { return .topRight }
        if nearRight && inBottomCorner { return .bottomRight }
        if nearTop && inLeftCorner { return .topLeft }
        if nearTop && inRightCorner { return .topRight }
        if nearBottom && inLeftCorner { return .bottomLeft }
        if nearBottom && inRightCorner { return .bottomRight }

        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .maximize }
        if nearBottom { return .bottom }
        return nil
    }

    /// The zone an arrow key implies, for keyboard snapping.
    ///
    /// The four arrows map to the four halves. Symmetry is the point: an arrow that
    /// halves the screen in the direction it points is predictable without being learned,
    /// whereas mapping Up to "maximise" makes Up the odd one out and leaves no way to get
    /// the top half at all. Maximise moves to Return, which is where Rectangle and Magnet
    /// both put it.
    static func zone(forKeyCode keyCode: Int64) -> SnapZone? {
        switch keyCode {
        case 123: return .left        // ←
        case 124: return .right       // →
        case 126: return .top         // ↑
        case 125: return .bottom      // ↓
        case 36, 76: return .maximize // Return / Enter
        case 83:  return .bottomLeft  // numpad 1
        case 84:  return .bottom      // numpad 2
        case 85:  return .bottomRight // numpad 3
        case 86:  return .left        // numpad 4
        case 87:  return .centre      // numpad 5
        case 88:  return .right       // numpad 6
        case 89:  return .topLeft     // numpad 7
        case 91:  return .top         // numpad 8
        case 92:  return .topRight    // numpad 9
        default: return nil
        }
    }
}
