import CoreGraphics
import Foundation

/// A captured window image.
///
/// `CGImage` is an immutable CoreFoundation type that is safe to read from any thread,
/// but it carries no `Sendable` conformance, so this wrapper carries it across
/// isolation boundaries with the reason stated rather than silently suppressed.
nonisolated struct Thumbnail: @unchecked Sendable {
    let image: CGImage
    /// When this was captured, used to decide whether a refresh is due.
    let captured: Date
    /// False when the window was off-screen at capture time, so the pixels are a
    /// last-known state rather than live content.
    let isLive: Bool

    var size: CGSize { CGSize(width: image.width, height: image.height) }
}
