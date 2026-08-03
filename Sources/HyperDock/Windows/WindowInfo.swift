import CoreGraphics
import Foundation

/// One window, flattened into plain values so it can cross isolation boundaries.
///
/// Assembled from three sources, because no single one can answer everything:
///
/// | need                        | source                                          |
/// |-----------------------------|-------------------------------------------------|
/// | title, frame, on-screen     | `SCShareableContent`                            |
/// | which Space it lives on     | CGS per-Space enumeration                       |
/// | raise / close / minimise    | Accessibility, resolved lazily at action time   |
///
/// In particular the Accessibility API cannot *enumerate* these: `kAXWindowsAttribute`
/// is filtered to the current Space and returns an empty array for an application whose
/// windows are all elsewhere.
nonisolated struct WindowInfo: Identifiable, Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let applicationName: String
    /// Global, top-left origin coordinates.
    let frame: CGRect

    /// The Mission Control desktop number this window sits on, if known.
    /// `nil` when the Space SPI is unavailable or the window belongs to none.
    let spaceNumber: Int?
    let isOnCurrentSpace: Bool

    /// True when the window is minimised into the Dock.
    ///
    /// Derived rather than asked for: a minimised window keeps its Space membership, so
    /// a window that belongs to the *current* Space yet is not on screen must be
    /// minimised or its application hidden. A window on another Space is simply
    /// elsewhere, not minimised.
    let isMinimized: Bool

    /// Whether the window is currently composited, and so whether a fresh thumbnail
    /// will show live content.
    let isOnScreen: Bool

    /// True when the window cannot currently be seen — the case the original shades and
    /// stamps with a Space number.
    var isInvisible: Bool { !isOnScreen }

    var aspectRatio: CGFloat {
        guard frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }
}
