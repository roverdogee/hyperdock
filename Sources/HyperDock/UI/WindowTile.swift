import SwiftUI

/// One window preview, presented as a card.
///
/// The card is the design's one deliberate flourish: at rest it is a flat thumbnail with a
/// hairline edge; focused, it lifts slightly, gains a ring in the user's system accent
/// colour, and its title sharpens. Scrubbing the row then reads as flipping through
/// cards, which makes the current target unmistakable at a glance — the thing that
/// matters when this surface is only on screen for a moment.
///
/// The visual treatment follows HyperDock 1.8, including dimming windows that are not
/// on the current Space and using the original close-button artwork.
struct WindowTile: View {
    let window: WindowInfo
    let thumbnail: Thumbnail?
    let width: CGFloat
    let height: CGFloat
    let maximumHeight: CGFloat
    let isFocused: Bool
    let isFrontWindow: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var preferences = Preferences.shared
    @State private var closeButtonIsVisible = false
    @State private var closeButtonIsHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Design.titleGap) {
            card
                // The old screenshot layer centred its contents in the maximum preview
                // rectangle on both axes. The title remains on the shared row baseline.
                .frame(width: width, height: maximumHeight, alignment: .center)
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
        .task(id: isFocused) {
            closeButtonIsVisible = false
            closeButtonIsHovered = false
            guard isFocused else { return }
            try? await Task.sleep(for: .milliseconds(max(0, preferences.closeButtonDelay)))
            guard !Task.isCancelled else { return }
            closeButtonIsVisible = true
        }
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
        (window.isMinimized || !window.isOnCurrentSpace) && preferences.shadeInvisibleWindows
    }

    private var card: some View {
        ZStack {
            thumbnailLayer
            // A permanent inner hairline keeps white screenshots distinct from light
            // glass. Drawing it inside the clipped card avoids the rectangular corner
            // shadows produced by an outer layer or a view-level shadow.
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: 0.75)
                .allowsHitTesting(false)
            if isFrontWindow {
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .strokeBorder(frontWindowBorderColor, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            if highlighted {
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
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
                    .opacity(closeButtonIsVisible ? 1 : 0)
                    .motion(Design.focus, value: closeButtonIsVisible, reduced: reduceMotion)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .scaleEffect(highlighted ? Design.focusScale : 1)
        .motion(Design.focus, value: highlighted, reduced: reduceMotion)
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // A minimised window is not on any screen, so its pixels are a memory.
                // Draining the colour says that without hiding what the window is.
                .saturation(dimmed ? 0.45 : 1)
                .opacity(dimmed ? 0.58 : 1)
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
                if preferences.theme == .liquidGlass {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                closeButtonIsHovered
                                    ? Color.red
                                    : liquidCloseButtonColor.opacity(0.88)
                            )
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(
                        AnimatedCloseButtonStyle(
                            isHovered: closeButtonIsHovered,
                            reduceMotion: reduceMotion
                        )
                    )
                    .onHover(perform: updateCloseButtonHover)
                    .accessibilityLabel(Text("Close window"))
                } else {
                    Button(action: onClose) { Color.clear }
                        .buttonStyle(OriginalCloseButtonStyle(
                            normalAsset: closeButtonAsset,
                            pressedAsset: closeButtonPressedAsset,
                            size: usesLightBubble ? 30 : 28
                        ))
                        .accessibilityLabel(Text("Close window"))
                }
                Spacer()
            }
            Spacer()
        }
        // The archived artwork already contains a one-point transparent margin. Adding
        // layout padding on top of it made the visible circle float too far inward.
        // Align its canvas directly with the screenshot's top-leading corner instead.
    }

    private func updateCloseButtonHover(_ isHovered: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            closeButtonIsHovered = isHovered
        }
    }

    private var liquidCloseButtonColor: Color {
        usesLightBubble ? .black : .white
    }

    private var usesLightBubble: Bool {
        preferences.theme == .vibrantLight
            || ([.automatic, .liquidGlass].contains(preferences.theme)
                && colorScheme == .light)
    }

    private var closeButtonAsset: String {
        usesLightBubble ? "closebox" : "closebox_white"
    }

    private var closeButtonPressedAsset: String {
        // The archived bundle only supplies a separate pressed image for the white
        // control; the dark glyph uses the normal artwork with the pressed transform.
        usesLightBubble ? "closebox" : "closebox_white_pressed"
    }

    // MARK: Title

    private var title: some View {
        Group {
            if hasDistinctWindowTitle {
                Text(displayTitle)
                    .font(highlighted ? Design.titleFocusedFont : Design.titleFont)
                    .lineLimit(1)
                    // Middle truncation keeps both ends: many windows in one app differ
                    // only in a leading path or trailing filename.
                    .truncationMode(.middle)
                    .foregroundStyle(titleColor.opacity(highlighted ? 1 : 0.88))
                    .help(Text(displayTitle))
            } else {
                // Keep a common card baseline while avoiding "ChatGPT" appearing once
                // as the app heading and again as a non-distinct window title.
                Color.clear
            }
        }
        .frame(width: width, height: Design.titleHeight)
    }

    private var hasDistinctWindowTitle: Bool {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = window.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.localizedCaseInsensitiveCompare(app) != .orderedSame
    }

    private var titleColor: Color {
        usesLightBubble ? .black : .white
    }

    private var cardBorderColor: Color {
        usesLightBubble ? .black.opacity(0.13) : .white.opacity(0.20)
    }

    private var frontWindowBorderColor: Color {
        usesLightBubble ? .black.opacity(0.19) : .white.opacity(0.30)
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

private struct OriginalCloseButtonStyle: ButtonStyle {
    let normalAsset: String
    let pressedAsset: String
    let size: CGFloat

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let asset = configuration.isPressed ? pressedAsset : normalAsset
        Group {
            if let image = OriginalHyperDockAssets.image(asset) {
                image
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary, .regularMaterial)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .opacity(configuration.isPressed ? 0.82 : 1)
        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
        .contentShape(Rectangle().inset(by: -4))
    }
}

private struct AnimatedCloseButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : (isHovered ? 1.12 : 1))
            .opacity(configuration.isPressed ? 0.58 : 1)
            // A small shadow keeps the borderless glyph visible over arbitrary window
            // contents without bringing back the old circular plate.
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0.18), radius: 1, y: 0.5)
            .contentShape(Rectangle().inset(by: -4))
            .animation(
                reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.66),
                value: configuration.isPressed
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovered
            )
    }
}
