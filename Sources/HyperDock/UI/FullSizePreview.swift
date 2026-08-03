import AppKit
import SwiftUI

/// The large preview that appears when the pointer rests on a thumbnail.
///
/// It lives in its **own panel** rather than growing the bubble. Resizing the bubble
/// would move every other thumbnail out from under the pointer, so the user would lose
/// their place the instant the preview appeared — the opposite of what a "look closer"
/// gesture should do. A separate panel leaves the bubble untouched.
@MainActor
final class FullSizePreviewController {
    private let panel: NSPanel
    private let model = FullSizePreviewModel()

    /// Whether the *next* hover uses the long delay or the short one.
    ///
    /// The first look costs 500 ms so the preview does not flash up while the pointer is
    /// merely crossing the bubble; once the user is clearly scrubbing, subsequent looks
    /// drop to 200 ms so scanning several windows stays responsive.
    private var hasShownOnce = false
    private var pendingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    /// The window the pending capture is for, so a capture that finishes after the
    /// pointer has moved on is discarded instead of shown.
    private var currentTarget: CGWindowID?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the bubble, which is at .popUpMenu, so it is never occluded by it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        // Purely informational: it must never intercept the pointer that summoned it.
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: FullSizePreviewView(model: model))
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
    }

    /// Called whenever the hovered preview changes. Passing `nil` cancels.
    func hover(_ window: WindowInfo?, bubbleFrame: CGRect) {
        pendingTask?.cancel()

        guard Preferences.shared.showFullSizePreviewOnHover, let window else {
            currentTarget = nil
            hide()
            return
        }

        // Same window as the one already showing: nothing to do. Without this, a stream
        // of hover events for the same tile would keep restarting the timer and, once
        // shown, keep re-presenting — which reads as a flicker.
        guard currentTarget != window.id else { return }
        currentTarget = window.id

        let delayMilliseconds = hasShownOnce
            ? Preferences.shared.fullSizePreviewDelaySubsequent
            : Preferences.shared.fullSizePreviewDelayFirst

        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(0, delayMilliseconds)))
            guard !Task.isCancelled, let self else { return }
            await self.present(window, bubbleFrame: bubbleFrame)
        }
    }

    func hide() {
        pendingTask?.cancel()
        pendingTask = nil
        currentTarget = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        model.thumbnail = nil

        // Leaving the bubble entirely resets the pacing, so returning later gets the
        // deliberate first-look delay again instead of an instant pop.
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.hasShownOnce = false
        }
    }

    // MARK: - Presentation

    private func present(_ window: WindowInfo, bubbleFrame: CGRect) async {
        guard let screen = ScreenGeometry.screen(containing: CGPoint(x: bubbleFrame.midX,
                                                                    y: bubbleFrame.midY))
        else { return }

        // Big enough to actually read, but never more than half the screen.
        let maxWidth = min(screen.visibleFrame.width * 0.5, 900)
        let maxHeight = screen.visibleFrame.height * 0.55
        var width = maxWidth
        var height = width / max(window.aspectRatio, 0.2)
        if height > maxHeight {
            height = maxHeight
            width = height * window.aspectRatio
        }

        let scale = screen.backingScaleFactor
        let destination = place(size: CGSize(width: width, height: height),
                                above: bubbleFrame, on: screen)

        // Capture BEFORE showing anything. Ordering the panel in first and awaiting the
        // capture afterwards is what made it flash: the window appeared holding either
        // nothing or the *previous* window's image, then swapped a moment later.
        let thumbnail = await ThumbnailEngine.shared.fullSize(window, targetWidth: width * scale)
        guard !Task.isCancelled, let thumbnail else { return }

        // The pointer may have moved on during the capture; presenting now would show a
        // preview of a window the user has already left.
        guard currentTarget == window.id else { return }

        model.window = window
        model.thumbnail = thumbnail

        let alreadyVisible = panel.isVisible
        panel.setFrame(destination, display: alreadyVisible)

        if alreadyVisible {
            // Scrubbing between previews: the panel is already up and only its content
            // and geometry change, so there is nothing to fade.
            panel.invalidateShadow()
        } else {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.hasShadow = false
            panel.orderFrontRegardless()

            if reduceMotion {
                panel.hasShadow = true
                panel.invalidateShadow()
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                } completionHandler: { [weak self] in
                    // AppKit delivers this on the main thread; its parameter type just
                    // cannot say so.
                    MainActor.assumeIsolated {
                        self?.panel.hasShadow = true
                        self?.panel.invalidateShadow()
                    }
                }
            }
        }

        hasShownOnce = true
        resetTask?.cancel()
    }

    /// Sits above the bubble by preference, flipping below it when there is no room —
    /// never on top of the bubble the pointer is currently in.
    private func place(size: CGSize, above bubble: CGRect, on screen: NSScreen) -> CGRect {
        let area = screen.visibleFrame
        let gap: CGFloat = 10

        var origin = CGPoint(x: bubble.midX - size.width / 2, y: bubble.maxY + gap)
        if origin.y + size.height > area.maxY {
            origin.y = bubble.minY - size.height - gap
        }
        origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
        origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
@Observable
final class FullSizePreviewModel {
    var window: WindowInfo?
    var thumbnail: Thumbnail?
}

private struct FullSizePreviewView: View {
    @Bindable var model: FullSizePreviewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.bubbleRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let thumbnail = model.thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(alignment: .bottom) {
            if let title = model.window?.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.thinMaterial),
                        in: Capsule()
                    )
                    .padding(10)
            }
        }
        .overlay {
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
    }
}
