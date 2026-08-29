import SwiftUI

/// The bubble's design tokens, in one place so the panel's geometry maths and the
/// SwiftUI content can never disagree about a number.
///
/// The guiding constraint is that this surface appears on hover, lives for a few hundred
/// milliseconds, and sits on top of whatever the user is actually working on. Everything
/// here serves *time to target*: legibility first, decoration only where it helps the eye
/// land. It also has to read as part of macOS, so colours are drawn from system semantic
/// styles and the user's own accent colour rather than an imposed palette.
enum Design {

    // MARK: Spacing — a 4pt grid

    static let gridUnit: CGFloat = 4

    /// Padding between the bubble's edge and its content.
    /// Matches the compact inset of the original Classic preview bubble.
    static let bubblePadding: CGFloat = 9
    /// Gap between preview cards.
    static let cardGap: CGFloat = 8
    /// Gap between a card's thumbnail and its title.
    static let titleGap: CGFloat = 4
    /// Height reserved for a card's title line.
    static let titleHeight: CGFloat = 17
    /// Height of the header strip carrying the app name and actions.
    static let headerHeight: CGFloat = 22

    // MARK: Geometry

    static let bubbleRadius: CGFloat = 14
    static let cardRadius: CGFloat = 3
    static let pointerWidth: CGFloat = 24
    static let pointerLength: CGFloat = 11
    static let badgeRadius: CGFloat = 5

    /// How much a focused card grows. Small on purpose: the card must not overlap its
    /// neighbours, or scrubbing across the row makes tiles jump under the pointer.
    static let focusScale: CGFloat = 1.0

    // MARK: Type
    //
    // Window titles are the primary content: the user already knows which application
    // they hovered, so the app name is context, not headline. This inverts the original,
    // which set the app name largest and centred.

    static let titleFont = Font.system(size: 12, weight: .regular)
    static let titleFocusedFont = Font.system(size: 12, weight: .regular)
    static let appNameFont = Font.system(size: 13, weight: .semibold)
    static let badgeFont = Font.system(size: 10, weight: .semibold)

    // MARK: Motion

    static let appear = Animation.interpolatingSpring(stiffness: 500, damping: 38)
    static let focus = Animation.easeOut(duration: 0.10)
    /// The pointer slides along the bubble's edge rather than the whole bubble jumping
    /// when the user moves to an adjacent Dock icon.
    static let pointerSlide = Animation.easeOut(duration: 0.14)
}

// MARK: - Accessibility

extension EnvironmentValues {
    /// True when the user has asked for less motion, so animations should be dropped
    /// rather than merely shortened.
    var prefersReducedMotion: Bool {
        accessibilityReduceMotion
    }
}

extension View {
    /// Applies an animation unless the user has asked for reduced motion.
    func motion(_ animation: Animation, value: some Equatable, reduced: Bool) -> some View {
        self.animation(reduced ? nil : animation, value: value)
    }
}
