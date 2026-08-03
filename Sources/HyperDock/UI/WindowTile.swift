import SwiftUI

/// One window preview, presented as a card.
///
/// The card is the design's one deliberate flourish: at rest it is a flat thumbnail with a
/// hairline edge; focused, it lifts slightly, gains a ring in the user's system accent
/// colour, and its title sharpens. Scrubbing the row then reads as flipping through
/// cards, which makes the current target unmistakable at a glance — the thing that
/// matters when this surface is only on screen for a moment.
///
/// Two departures from the original are deliberate:
///
///  * A window on another Space keeps a **bright, readable thumbnail**. The original
///    covers it with a heavy scrim, which signals "elsewhere" at the cost of the
///    thumbnail — and the thumbnail is how the user recognises the window in the first
///    place. The Space is communicated with a badge instead.
///  * Only a **minimised** window is desaturated, because it genuinely is not on any
///    screen, so there is no live state to misrepresent.
struct WindowTile: View {
    let window: WindowInfo
    let thumbnail: Thumbnail?
    let width: CGFloat
    let height: CGFloat
    let isFocused: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var preferences = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: Design.titleGap) {
            card
            title
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // The card is one accessibility element carrying both of its actions.
        //
        // The close button itself cannot be relied on here: it is only visible on focus,
        // and SwiftUI removes a zero-opacity view from the accessibility tree entirely.
        // Verified by dumping the tree — the card appeared as an AXGroup of static text
        // with no button inside at all, so a window could only be closed with a pointer.
        // Exposing the actions on the card instead makes both reachable at all times,
        // and `.combine` keeps the window's title readable rather than discarding the
        // labels the way `.ignore` does.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: Text("Close window")) { onClose() }
    }

    // MARK: Card

    /// Whether the focused card gets its lift, ring and sharpened title.
    ///
    /// Separate from `isFocused` so that turning the highlight off does not also take the
    /// close button away with it — the button appears on focus, and focus still happens.
    private var highlighted: Bool {
        isFocused && preferences.drawHighlightGradient
    }

    /// Whether this thumbnail is shown as a memory rather than a live window.
    ///
    /// Scoped to minimised windows on purpose. A window on another Space is equally
    /// off screen, but its thumbnail is still how the user recognises it, and the badge
    /// already says where it is — draining it too would cost recognition and buy nothing.
    private var dimmed: Bool {
        window.isMinimized && preferences.shadeInvisibleWindows
    }

    private var card: some View {
        ZStack {
            thumbnailLayer
            if preferences.showSpaceIndicator { badge }
            // Visible only on focus, but present in the view tree either way.
            //
            // Two earlier attempts failed for the same underlying reason. Building it
            // conditionally left it absent from the accessibility tree; keeping it but
            // adding `.allowsHitTesting(false)` removed it just as thoroughly. Assistive
            // technology could never reach it, so a window could only be closed with a
            // pointer. Fading opacity alone keeps the control in the tree at all times —
            // and the card's own `Close window` accessibility action provides a
            // pointer-free route regardless.
            if preferences.showCloseButton {
                closeButton
                    .opacity(isFocused ? 1 : 0)
                    .motion(Design.focus, value: isFocused, reduced: reduceMotion)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(
                    highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.10)),
                    lineWidth: highlighted ? 2 : 1
                )
        }
        // The lift reads as depth rather than as a glow, so the shadow grows with it.
        .shadow(color: .black.opacity(highlighted ? 0.34 : 0.16),
                radius: highlighted ? 10 : 3,
                y: highlighted ? 4 : 1)
        .scaleEffect(highlighted ? Design.focusScale : 1)
        .motion(Design.focus, value: highlighted, reduced: reduceMotion)
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                // A minimised window is not on any screen, so its pixels are a memory.
                // Draining the colour says that without hiding what the window is.
                .saturation(dimmed ? 0.35 : 1)
                .opacity(dimmed ? 0.75 : 1)
        } else {
            // A neutral plate rather than a spinner: thumbnails land within ~130 ms and a
            // spinner that appears and vanishes that fast is just a flicker.
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "macwindow")
                        .font(.system(size: min(height * 0.28, 26), weight: .light))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    // MARK: Badge

    /// Says where the window is, when that is not "right here".
    ///
    /// Sits on a material plate so it stays legible over an arbitrary screenshot — a
    /// plain translucent fill can vanish against a light document or a dark terminal.
    @ViewBuilder
    private var badge: some View {
        if window.isMinimized {
            badgePlate {
                Label {
                    Text("Minimized")
                } icon: {
                    Image(systemName: "minus")
                }
            }
        } else if !window.isOnCurrentSpace, let number = window.spaceNumber {
            badgePlate {
                Text("Desktop \(number)")
            }
        }
    }

    private func badgePlate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content()
                    .font(Design.badgeFont)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.thinMaterial),
                        in: RoundedRectangle(cornerRadius: Design.badgeRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.badgeRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
            }
        }
        .padding(6)
    }

    // MARK: Close button

    private var closeButton: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 18, height: 18)
                        .background(.thinMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                        // A generous hit area around a small glyph: the visible control
                        // stays unobtrusive while remaining easy to actually hit.
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close window"))
                Spacer()
            }
            Spacer()
        }
        .padding(6)
    }

    // MARK: Title

    private var title: some View {
        Text(displayTitle)
            .font(highlighted ? Design.titleFocusedFont : Design.titleFont)
            .lineLimit(1)
            // Middle truncation keeps both ends: many windows in one app differ only in
            // a leading path or a trailing filename, and tail truncation would hide it.
            .truncationMode(.middle)
            .foregroundStyle(highlighted ? .primary : .secondary)
            .frame(width: width, height: Design.titleHeight)
            .help(Text(displayTitle))
    }

    /// Falls back to the application name so a window with no title is still identifiable
    /// rather than showing an empty line.
    private var displayTitle: String {
        window.title.isEmpty ? window.applicationName : window.title
    }

    private var accessibilityDescription: String {
        var parts = [displayTitle]
        if window.isMinimized {
            parts.append(Localization.string("Minimized"))
        } else if !window.isOnCurrentSpace, let number = window.spaceNumber {
            parts.append(String(format: Localization.string("Desktop %d"), number))
        }
        return parts.joined(separator: ", ")
    }
}
