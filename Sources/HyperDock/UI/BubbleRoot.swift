import SwiftUI

/// The preview bubble's content.
///
/// Two structural decisions differ from the original, both in service of how fast this
/// surface can be read:
///
///  * The **window titles are the headline**, not the application name. The user just
///    hovered that icon, so the app is context they already have; what they are scanning
///    for is which window. The app name is therefore a small label in the corner.
///  * The bubble is backed by Liquid Glass, applied the one way that works in a
///    borderless transparent `NSPanel`: `Color.clear.glassEffect(_:in:)` as a background
///    layer. An earlier attempt applied `glassEffect` directly to the content stack and
///    concluded the API renders nothing in such a panel — the sibling switcher project
///    then shipped the background-layer form successfully in an identically configured
///    panel, which is the recipe used here. The glass follows the whole `BubbleShape`,
///    pointer included, and brings its own edge light, so the hand-drawn hairline that
///    the material needed is gone rather than doubled.
struct BubbleRoot: View {
    @Bindable var model: BubbleModel
    @State private var preferences = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: BubbleShape {
        BubbleShape(
            pointerPosition: model.pointerPosition,
            edge: model.edge,
            cornerRadius: Design.bubbleRadius,
            pointerWidth: Design.pointerWidth,
            pointerLength: Design.pointerLength,
            showsPointer: preferences.drawTriangle
        )
    }

    var body: some View {
        content
            .padding(Design.bubblePadding)
            .padding(pointerEdge, preferences.drawTriangle ? Design.pointerLength : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { backdrop }
            // The glass follows the path, but child views would still paint into the
            // pointer's notch without this clip.
            .clipShape(shape)
            // Scale about the pointer, so the bubble grows out of the Dock icon it
            // belongs to rather than out of its own middle.
            .scaleEffect(model.snapScale, anchor: growthAnchor)
            // One compositing layer, so the whole bubble scales as a single piece rather
            // than each tile animating its own geometry and visibly reflowing.
            //
            // Deliberately `compositingGroup` and not `drawingGroup`: the latter
            // rasterises into an offscreen buffer, which would stop the material sampling
            // the desktop behind the panel and flatten the blur entirely.
            .compositingGroup()
            .motion(Design.pointerSlide, value: model.pointerPosition, reduced: reduceMotion)
            .localizedFollowingPreference()
    }

    /// Reduce Transparency asks for an opaque surface, and glass is the opposite of one.
    /// The opaque branch keeps a hairline edge: without glass's own edge light, a light
    /// plate on a light desktop loses its silhouette.
    @ViewBuilder
    private var backdrop: some View {
        if reduceTransparency {
            shape.fill(.background)
                .overlay { shape.stroke(.white.opacity(0.14), lineWidth: 1) }
        } else {
            Color.clear.glassEffect(.regular, in: shape)
        }
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
        VStack(alignment: .leading, spacing: Design.titleGap) {
            if preferences.showApplicationName { header }
            grid
        }
    }

    /// A quiet context strip: which app, how many windows, and the new-window action.
    private var header: some View {
        HStack(spacing: 6) {
            Text(model.applicationName)
                .font(Design.appNameFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("\(model.windows.count)")
                .font(Design.badgeFont)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())

            Spacer(minLength: 8)

            Button(action: model.onNewWindow) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("New Window (⌘N)"))
            .accessibilityLabel(Text("New Window (⌘N)"))

            // Batch actions live behind a menu rather than as more buttons in the strip:
            // they act on every window at once, so putting them a deliberate click away
            // is the point — a stray click on the header should not close six windows.
            Menu {
                Button {
                    model.onTileAll()
                } label: {
                    Label("Tile Windows in a Grid", systemImage: "square.grid.2x2")
                }
                Button {
                    model.onMinimizeAll()
                } label: {
                    Label("Minimize All Windows", systemImage: "minus.rectangle")
                }
                Button(role: .destructive) {
                    model.onCloseAll()
                } label: {
                    Label("Close All Windows", systemImage: "xmark.rectangle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help(Text("More actions"))
            .accessibilityLabel(Text("More actions"))
        }
        .frame(height: Design.headerHeight)
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.fixed(model.thumbnailWidth), spacing: Design.cardGap),
            count: model.columnCount
        )
        return LazyVGrid(columns: columns, spacing: Design.cardGap) {
            ForEach(model.windows) { window in
                WindowTile(
                    window: window,
                    thumbnail: model.thumbnails[window.id],
                    width: model.thumbnailWidth,
                    height: model.thumbnailHeight,
                    isFocused: model.focusedWindowID == window.id,
                    onSelect: { model.onSelect(window) },
                    onClose: { model.onClose(window) }
                )
                .onHover { inside in
                    if inside {
                        model.hoveredWindow = window.id
                        // Pointer movement takes focus back from the keyboard, so the two
                        // never disagree about which tile is highlighted.
                        model.keyboardFocusIndex = nil
                    } else if model.hoveredWindow == window.id {
                        model.hoveredWindow = nil
                    }
                }
            }
        }
    }
}
