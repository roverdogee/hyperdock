import AppKit
import Observation
import SwiftUI

/// State backing the preview bubble, and the geometry maths that sizes it.
@MainActor
@Observable
final class BubbleModel {
    var windows: [WindowInfo] = []
    var applicationName: String = ""
    var thumbnails: [CGWindowID: Thumbnail] = [:]
    var edge: DockEdge = .bottom
    var pointerPosition: CGFloat = 0
    var snapScale: CGFloat = 1

    /// The preview under the pointer.
    var hoveredWindow: CGWindowID? {
        didSet { onFocusChange?() }
    }

    /// Fired whenever the focused preview changes, so the full-size preview can follow.
    var onFocusChange: (() -> Void)?
    /// The preview selected with the keyboard. Independent of hover so the two do not
    /// fight: whichever the user last used wins, and moving the mouse takes over again.
    var keyboardFocusIndex: Int? {
        didSet { onFocusChange?() }
    }

    var onSelect: (WindowInfo) -> Void = { _ in }
    var onClose: (WindowInfo) -> Void = { _ in }
    var onNewWindow: () -> Void = {}

    /// Which preview currently reads as focused, from either input.
    var focusedWindowID: CGWindowID? {
        if let index = keyboardFocusIndex, windows.indices.contains(index) {
            return windows[index].id
        }
        return hoveredWindow
    }

    var focusedWindow: WindowInfo? {
        guard let id = focusedWindowID else { return nil }
        return windows.first { $0.id == id }
    }

    /// Foremost app window, independent of the preview currently under the pointer.
    var frontWindowID: CGWindowID? {
        windows.min(by: { $0.stackingIndex < $1.stackingIndex })?.id
    }

    /// Moves keyboard focus, wrapping at both ends so holding an arrow key cycles.
    func moveFocus(by delta: Int) {
        guard !windows.isEmpty else { return }
        let current: Int
        if let index = keyboardFocusIndex {
            current = index
        } else if let hovered = hoveredWindow,
                  let index = windows.firstIndex(where: { $0.id == hovered }) {
            // Picking up from the hovered tile means the first arrow press continues
            // from where the user is already looking.
            current = index
        } else {
            current = delta > 0 ? -1 : 0
        }
        let count = windows.count
        keyboardFocusIndex = ((current + delta) % count + count) % count
    }

    // MARK: - Metrics

    /// Layout numbers derived from the bubble-size slider and the previews-per-row
    /// setting, kept in one place so the panel and the view agree on the size.
    struct Metrics {
        let size: CGSize
        let thumbnailWidth: CGFloat
        let columns: Int
    }

    /// The thumbnail width the slider currently asks for.
    ///
    /// The mapping is deliberately piecewise. Almost two thirds of the control is devoted
    /// to useful compact sizes, while the rarely needed 300+ range occupies its last 15%.
    var thumbnailWidth: CGFloat {
        CGFloat(Self.thumbnailWidth(forSliderValue: Preferences.shared.bubbleSize))
    }

    nonisolated static func thumbnailWidth(forSliderValue rawValue: Double) -> Double {
        let value = min(max(rawValue, 0), 1)
        switch value {
        case ..<0.65:
            return 115 + 125 * value / 0.65
        case ..<0.85:
            return 240 + 60 * (value - 0.65) / 0.20
        default:
            return 300 + 20 * (value - 0.85) / 0.15
        }
    }

    /// Inverse used once to migrate the earlier native build without changing the size
    /// already visible on the user's screen.
    nonisolated static func sliderValue(forThumbnailWidth rawWidth: Double) -> Double {
        let width = min(max(rawWidth, 115), 320)
        switch width {
        case ..<240:
            return (width - 115) / 125 * 0.65
        case ..<300:
            return 0.65 + (width - 240) / 60 * 0.20
        default:
            return 0.85 + (width - 300) / 20 * 0.15
        }
    }

    /// Maximum thumbnail height. HyperDock 1.8 fitted every window into one maximum
    /// rectangle; it did not derive the whole row's height from the hovered app. This is
    /// especially important for portrait windows such as iPhone Mirroring.
    var thumbnailHeight: CGFloat {
        // The old 4:3 item rectangle reserved 26 pt vertically and 14 pt horizontally:
        // h = 0.75 × (effectiveWidth + 14) - 26.
        (thumbnailWidth * 0.75 - 15.5).rounded()
    }

    /// Aspect-fitted size inside the fixed maximum preview rectangle used by the old
    /// helper. Wide windows consume the maximum width; tall windows consume the maximum
    /// height and become narrower instead of making the bubble taller.
    nonisolated static func fittedThumbnailSize(aspectRatio: CGFloat,
                                                 maximum: CGSize) -> CGSize {
        let ratio = min(max(aspectRatio, 0.1), 10)
        let maximumRatio = maximum.width / maximum.height
        if ratio >= maximumRatio {
            return CGSize(width: maximum.width,
                          height: max(1, (maximum.width / ratio).rounded()))
        }
        return CGSize(width: max(1, (maximum.height * ratio).rounded()),
                      height: maximum.height)
    }

    func thumbnailSize(for window: WindowInfo) -> CGSize {
        Self.fittedThumbnailSize(
            aspectRatio: window.aspectRatio,
            maximum: CGSize(width: thumbnailWidth, height: thumbnailHeight)
        )
    }

    var rows: [[WindowInfo]] {
        let columns = columnCount
        guard columns > 0 else { return [] }
        return stride(from: 0, to: windows.count, by: columns).map { start in
            Array(windows[start..<min(start + columns, windows.count)])
        }
    }

    /// Columns to lay the previews out in.
    ///
    /// HyperDock fills one row to the configured maximum before beginning the next.
    /// At the original default, six previews are therefore arranged as 5 + 1.
    var columnCount: Int {
        let limit = max(1, Preferences.shared.previewsPerRow)
        return min(max(1, windows.count), limit)
    }

    func metrics(for edge: DockEdge) -> Metrics {
        let columns = columnCount
        let previewRows = rows
        let rowWidths = previewRows.map { row in
            row.reduce(CGFloat.zero) { $0 + thumbnailSize(for: $1).width }
                + CGFloat(max(0, row.count - 1)) * Design.cardGap
        }
        let contentWidth = max(rowWidths.max() ?? thumbnailWidth, thumbnailWidth)
        let width = contentWidth + Design.bubblePadding * 2

        let rowCount = max(1, previewRows.count)
        var height = CGFloat(rowCount) * (thumbnailHeight + Design.titleGap + Design.titleHeight)
            + CGFloat(rowCount - 1) * Design.cardGap
            + Design.bubblePadding * 2
        if Preferences.shared.showApplicationName {
            height += Design.headerHeight + Design.titleGap
        }

        var size = CGSize(width: width, height: height)
        if Preferences.shared.drawTriangle {
            switch edge {
            case .bottom: size.height += Design.pointerLength
            case .left, .right: size.width += Design.pointerLength
            }
        }
        return Metrics(size: size, thumbnailWidth: thumbnailWidth, columns: columns)
    }

    // MARK: - Updates

    func update(windows: [WindowInfo], applicationName: String) {
        self.applicationName = applicationName
        self.windows = windows
        hoveredWindow = nil
        keyboardFocusIndex = nil
        // Keep images for windows that survived, drop the rest so a stale thumbnail never
        // shows under a different window's title.
        let live = Set(windows.map(\.id))
        thumbnails = thumbnails.filter { live.contains($0.key) }
    }

    func clear() {
        windows = []
        thumbnails = [:]
        hoveredWindow = nil
        keyboardFocusIndex = nil
        snapScale = 1
    }

    /// The "snap in" popup animation: a brief scale-up as the bubble appears.
    func snapIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            snapScale = 1
            return
        }
        snapScale = 0.92
        withAnimation(Design.appear) { snapScale = 1 }
    }
}
