import SwiftUI

/// Recreates the four appearance modes exposed by HyperDock 1.8 and adds a fifth native
/// Liquid Glass mode.
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
            cornerRadius: preferences.theme == .liquidGlass ? 18 : 9,
            pointerWidth: Design.pointerWidth,
            pointerLength: Design.pointerLength,
            smoothPointer: preferences.theme == .liquidGlass,
            showsPointer: showsPointer
        )
    }

    /// Leaves room inside the transparent NSPanel for the system glass halo. Without
    /// this margin the compositor clips that halo to the rectangular window boundary,
    /// leaving short grey shelves outside the two top corners.
    private var liquidShape: BubbleShape { shape.inset(by: 2.5) }

    @ViewBuilder
    var body: some View {
        if preferences.theme == .liquidGlass {
            // Let the clear system material draw both the backdrop and its refractive
            // rim. An extra fill made the result darker, while a manual stroke covered
            // the very edge highlights that distinguish glass from a translucent plate.
            liquidShape
                .fill(.clear)
                .glassEffect(.clear.interactive(), in: liquidShape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            shape
                .fill(fillStyle)
                .overlay { shape.stroke(borderColor, lineWidth: 1) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch preferences.theme {
        case .classic:
            AnyShapeStyle(Color(red: 0.10, green: 0.075, blue: 0.12).opacity(0.93))
        case .vibrantLight, .vibrantDark, .automatic, .liquidGlass:
            AnyShapeStyle(.regularMaterial)
        }
    }

    private var isLight: Bool {
        preferences.theme == .vibrantLight
            || ([.automatic, .liquidGlass].contains(preferences.theme)
                && colorScheme == .light)
    }

    private var borderColor: Color {
        isLight ? .black.opacity(0.24) : .white.opacity(0.30)
    }

}
