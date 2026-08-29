import SwiftUI

/// The preview bubble's content, using HyperDock 1.8's original artwork and hierarchy.
struct BubbleRoot: View {
    @Bindable var model: BubbleModel
    @State private var preferences = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(Design.bubblePadding)
            .padding(pointerEdge, preferences.drawTriangle ? Design.pointerLength : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                OriginalHyperDockBackground(
                    pointerPosition: model.pointerPosition,
                    edge: model.edge,
                    showsPointer: preferences.drawTriangle
                )
            }
            // Scale about the pointer, so the bubble grows out of the Dock icon it
            // belongs to rather than out of its own middle.
            .scaleEffect(model.snapScale, anchor: growthAnchor)
            .motion(Design.pointerSlide, value: model.pointerPosition, reduced: reduceMotion)
            .localizedFollowingPreference()
    }

    /// Where the entrance animation scales from: the point of the pointer triangle, so
    /// the bubble appears to emerge from the Dock icon.
    private var growthAnchor: UnitPoint {
        guard preferences.drawTriangle else { return .center }
        switch model.edge {
        case .bottom:
            let width = model.metrics(for: .bottom).size.width
            guard width > 0 else { return .bottom }
            return UnitPoint(x: min(max(model.pointerPosition / width, 0), 1), y: 1)
        case .left:
            return .leading
        case .right:
            return .trailing
        }
    }

    private var pointerEdge: Edge.Set {
        switch model.edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var content: some View {
        VStack(alignment: .center, spacing: Design.titleGap) {
            if preferences.showApplicationName { header }
            grid
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// HyperDock presents the application name as the centred heading.
    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 18, height: 18)

            Spacer(minLength: 0)

            Text(model.applicationName)
                .font(Design.appNameFont)
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: model.onNewWindow) {
                // The original bundle only contains a 16×16 1× bitmap. Reconstruct the
                // same glyph as a vector so it remains crisp on Retina displays.
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(primaryTextColor)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("New Window (⌘N)"))
            .accessibilityLabel(Text("New Window (⌘N)"))
        }
        .frame(height: Design.headerHeight)
    }

    private var primaryTextColor: Color {
        if preferences.theme == .vibrantLight
            || (preferences.theme == .automatic && colorScheme == .light) {
            return .black.opacity(0.86)
        }
        return .white
    }

    private var grid: some View {
        VStack(spacing: Design.cardGap) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: Design.cardGap) {
                    ForEach(row) { window in
                        let size = model.thumbnailSize(for: window)
                        WindowTile(
                            window: window,
                            thumbnail: model.thumbnails[window.id],
                            width: size.width,
                            height: size.height,
                            maximumHeight: model.thumbnailHeight,
                            isFocused: model.focusedWindowID == window.id,
                            isFrontWindow: model.frontWindowID == window.id,
                            onSelect: { model.onSelect(window) },
                            onClose: { model.onClose(window) }
                        )
                        .onHover { inside in
                            if inside {
                                model.hoveredWindow = window.id
                                model.keyboardFocusIndex = nil
                            } else if model.hoveredWindow == window.id {
                                model.hoveredWindow = nil
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
