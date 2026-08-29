import SwiftUI

/// Which edge the Dock sits on, and therefore which way the bubble's pointer aims.
enum DockEdge: Sendable {
    case bottom, left, right

    var isHorizontal: Bool { self == .bottom }
}

/// The preview bubble outline: a rounded rectangle with a triangular pointer aimed at
/// the Dock icon that opened it.
///
/// This is a single `Shape` rather than a rectangle with a separate triangle view so
/// that the Liquid Glass material, the border and the shadow all follow one continuous
/// path. `glassEffect(_:in:)` renders correctly along an arbitrary shape, and a shadow
/// cast from two overlapping views would show a seam where they meet.
struct BubbleShape: Shape {
    /// Where the pointer meets the body, in the shape's own coordinate space. Tracks
    /// the Dock icon, which moves as the Dock magnifies or slides in.
    var pointerPosition: CGFloat
    var edge: DockEdge
    var cornerRadius: CGFloat = 12
    var pointerWidth: CGFloat = 22
    var pointerLength: CGFloat = 10
    /// Lets the pointer animate along the edge when the user slides to a neighbouring
    /// icon instead of the whole bubble jumping.
    var showsPointer: Bool = true

    var animatableData: CGFloat {
        get { pointerPosition }
        set { pointerPosition = newValue }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        guard showsPointer else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius)
        }

        // Reserve the pointer's depth out of the body so the overall shape still fits
        // the frame it was given.
        let body: CGRect
        switch edge {
        case .bottom: body = CGRect(x: rect.minX, y: rect.minY,
                                    width: rect.width, height: rect.height - pointerLength)
        case .left:   body = CGRect(x: rect.minX + pointerLength, y: rect.minY,
                                    width: rect.width - pointerLength, height: rect.height)
        case .right:  body = CGRect(x: rect.minX, y: rect.minY,
                                    width: rect.width - pointerLength, height: rect.height)
        }

        var path = Path(roundedRect: body, cornerRadius: cornerRadius)

        // Keep the pointer clear of the rounded corners, or it grows a visible notch.
        let inset = cornerRadius + pointerWidth / 2
        let half = pointerWidth / 2

        switch edge {
        case .bottom:
            let x = min(max(pointerPosition, body.minX + inset), body.maxX - inset)
            path.move(to: CGPoint(x: x - half, y: body.maxY))
            path.addLine(to: CGPoint(x: x, y: body.maxY + pointerLength))
            path.addLine(to: CGPoint(x: x + half, y: body.maxY))
            path.closeSubpath()

        case .left:
            let y = min(max(pointerPosition, body.minY + inset), body.maxY - inset)
            path.move(to: CGPoint(x: body.minX, y: y - half))
            path.addLine(to: CGPoint(x: body.minX - pointerLength, y: y))
            path.addLine(to: CGPoint(x: body.minX, y: y + half))
            path.closeSubpath()

        case .right:
            let y = min(max(pointerPosition, body.minY + inset), body.maxY - inset)
            path.move(to: CGPoint(x: body.maxX, y: y - half))
            path.addLine(to: CGPoint(x: body.maxX + pointerLength, y: y))
            path.addLine(to: CGPoint(x: body.maxX, y: y + half))
            path.closeSubpath()
        }

        return path
    }
}
