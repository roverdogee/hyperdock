import SwiftUI

/// Recreates the four appearance modes exposed by HyperDock 1.8:
/// Automatic, Classic, Vibrant Light, and Vibrant Dark.
///
/// The first compatibility pass stretched the old nine-slice corner PNGs. Those files
/// include a large transparent optical margin intended for the original custom window,
/// which produced a second translucent frame in a modern SwiftUI panel. A single shape
/// gives the same compact silhouette as the old app while keeping the archived artwork
/// available for its buttons and media controls.
struct OriginalHyperDockBackground: View {
    let pointerPosition: CGFloat
    let edge: DockEdge
    let showsPointer: Bool

    @State private var preferences = Preferences.shared
    @Environment(\.colorScheme) private var colorScheme

    private var shape: BubbleShape {
        BubbleShape(
            pointerPosition: pointerPosition,
            edge: edge,
            cornerRadius: 9,
            pointerWidth: Design.pointerWidth,
            pointerLength: Design.pointerLength,
            showsPointer: showsPointer
        )
    }

    var body: some View {
        shape
            .fill(fillStyle)
            .overlay { shape.stroke(borderColor, lineWidth: 1) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fillStyle: AnyShapeStyle {
        switch preferences.theme {
        case .classic:
            AnyShapeStyle(Color(red: 0.10, green: 0.075, blue: 0.12).opacity(0.93))
        case .vibrantLight, .vibrantDark, .automatic:
            AnyShapeStyle(.regularMaterial)
        }
    }

    private var isLight: Bool {
        preferences.theme == .vibrantLight
            || (preferences.theme == .automatic && colorScheme == .light)
    }

    private var borderColor: Color {
        isLight ? .black.opacity(0.32) : .white.opacity(0.38)
    }
}
