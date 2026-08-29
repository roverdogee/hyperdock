import AppKit
import SwiftUI

/// The floating window the preview bubble lives in.
///
/// Every setting here was chosen against a measured constraint:
///
///   * `.nonactivatingPanel` plus `orderFrontRegardless()` shows the bubble without
///     making HyperDock the frontmost application, while clicks still reach SwiftUI
///     buttons. Calling `makeKey()` — even with `canBecomeKey` overridden — *does*
///     activate the process and steal focus, so it is never used.
///
///   * Level `.popUpMenu` (101), not `.floating`. `.floating` is level 3 and the Dock
///     sits at 20, so a bubble at `.floating` is drawn *underneath* the Dock. This is
///     the single most common visual bug for this kind of feature.
///
///   * `.canJoinAllSpaces` plus `.fullScreenAuxiliary` so the bubble follows the user
///     across Spaces and still appears over full-screen apps.
final class PreviewPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // HyperDock's original nine-slice artwork already contains its own shadow.
        // Asking AppKit for another one creates the repeated black outlines visible in
        // early compatibility builds.
        hasShadow = false
        // Dock title bubbles sit above ordinary pop-up-menu windows. The original helper
        // used a private high window level; screen-saver level is the closest stable
        // public equivalent and lets our bubble cover the Dock's duplicate app label.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        acceptsMouseMovedEvents = true
        isMovable = false
        animationBehavior = .none
    }

    /// A `.borderless` window reports `canBecomeKey == false` by default, and that stops
    /// mouse events reaching its content — clicking a preview did nothing at all until
    /// this override was added.
    ///
    /// Allowing key status is safe here because focus is only *taken* by calling
    /// `makeKey()`, which this app never does: the panel is only ever shown with
    /// `orderFrontRegardless()`. Combined with `.nonactivatingPanel`, that lets clicks
    /// through while leaving the user's frontmost application untouched.
    override var canBecomeKey: Bool { true }

    /// Main status would make the app frontmost, which this panel must never do.
    override var canBecomeMain: Bool { false }
}

/// Serialises show/hide animations while preserving a committed click barrier.
///
/// Ordinary dismissal may be superseded by a new hover. A hide carrying a completion is
/// different: the completion performs the user's click after the all-Spaces panel is off
/// screen, so neither a duplicate hide nor an asynchronous reload may invalidate it.
struct PreviewVisibilityState {
    enum HideDecision: Equatable {
        case start(generation: UInt)
        case coalesced
    }

    private(set) var generation: UInt = 0
    private(set) var isHiding = false
    private(set) var barrierPending = false

    mutating func beginShow() -> UInt? {
        guard !barrierPending else { return nil }
        isHiding = false
        generation &+= 1
        return generation
    }

    mutating func beginHide(hasBarrier: Bool) -> (decision: HideDecision,
                                                  acceptsBarrier: Bool) {
        // The first click wins. Accepting a second completion while the first click is
        // fading would launch two concurrent Space-switch Tasks when the panel hides.
        let acceptsBarrier = hasBarrier && !barrierPending
        if acceptsBarrier { barrierPending = true }
        guard !isHiding else { return (.coalesced, acceptsBarrier) }
        isHiding = true
        generation &+= 1
        return (.start(generation: generation), acceptsBarrier)
    }

    mutating func finishHide(generation: UInt) -> Bool {
        guard isHiding, self.generation == generation else { return false }
        isHiding = false
        barrierPending = false
        return true
    }
}

/// Owns the panel and drives its content, position and visibility.
@MainActor
final class PreviewPanelController {
    private let panel = PreviewPanel()
    private let model = BubbleModel()
    private var hostingView: NSHostingView<BubbleRoot>?
    private let fullSize = FullSizePreviewController()
    private let dockTooltip = DockTooltipSuppressor()
    private var lastHovered: CGWindowID?
    /// Distinguishes stale animation completions and protects click-driven hides.
    private var visibilityState = PreviewVisibilityState()
    private var pendingHideCompletions: [@Sendable () -> Void] = []

    /// Debounces the loss of focus, so crossing the gap between two tiles does not
    /// tear the full-size preview down and immediately rebuild it.
    private var focusSettle: Task<Void, Never>?

    /// The Dock tile the bubble is anchored to, kept so it can be re-laid-out when its
    /// contents change without waiting for the next hover.
    private var lastTileFrame: CGRect?

    init() {
        let root = BubbleRoot(model: model)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        // The panel is transparent and irregularly shaped; the hosting view must not
        // paint an opaque background behind the material.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        hostingView = hosting
        applyTheme()
        model.onFocusChange = { [weak self] in self?.syncFullSizePreview() }
    }

    /// Applies the Theme preference to the panel.
    ///
    /// Set on the `NSWindow` rather than through SwiftUI's `preferredColorScheme` so that
    /// the material itself resolves to the chosen appearance — a SwiftUI-only override
    /// would restyle the text while leaving the backdrop following the system.
    func applyTheme() {
        switch Preferences.shared.theme {
        case .automatic: panel.appearance = nil
        case .classic: panel.appearance = NSAppearance(named: .darkAqua)
        case .vibrantLight: panel.appearance = NSAppearance(named: .vibrantLight)
        case .vibrantDark: panel.appearance = NSAppearance(named: .vibrantDark)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// The bubble's frame in AppKit coordinates, for hover-intent tests.
    var frame: CGRect { panel.frame }

    /// The window the keyboard focus is on, if any.
    var focusedWindow: WindowInfo? { model.focusedWindow }

    /// Moves keyboard focus through the previews, wrapping at both ends.
    func moveFocus(by delta: Int) {
        model.moveFocus(by: delta)
    }

    /// The pixel width thumbnails should be captured at, so the capture matches what
    /// the grid will actually draw.
    ///
    /// The scale comes from the display the bubble is actually on, not from
    /// `NSScreen.main`. Two reasons, both of which bite on a multi-display Mac: with
    /// mixed densities — a Retina laptop beside a 1× external — capturing at the wrong
    /// screen's scale gives either a soft thumbnail or twice the pixels needed, and
    /// `NSScreen.main` means "the screen with the key window", which an agent app with no
    /// key window does not reliably have in the first place.
    var thumbnailWidth: CGFloat {
        let anchor = lastTileFrame.map {
            ScreenGeometry.appKitRect(fromAccessibility: $0)
        } ?? panel.frame
        let screen = ScreenGeometry.screen(
            containing: CGPoint(x: anchor.midX, y: anchor.midY))
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return model.thumbnailWidth * scale * Preferences.shared.thumbnailQuality.scale
    }

    /// Shows the bubble for a Dock tile.
    ///
    /// - Parameters:
    ///   - tileFrame: the Dock icon's frame in Accessibility (top-left origin) space.
    func show(windows: [WindowInfo],
              applicationName: String,
              tileFrame: CGRect,
              edge: DockEdge,
              onSelect: @escaping (WindowInfo) -> Void,
              onClose: @escaping (WindowInfo) -> Void,
              onNewWindow: @escaping () -> Void) {
        // A click has committed to a Space switch that must happen only after this
        // all-Spaces panel is gone. Ignore transient reloads until that barrier drains.
        guard let generation = visibilityState.beginShow() else { return }
        applyTheme()
        model.update(windows: windows, applicationName: applicationName)
        model.edge = edge
        model.onSelect = onSelect
        model.onClose = onClose
        model.onNewWindow = onNewWindow

        lastTileFrame = tileFrame
        dockTooltip.suppress(around: tileFrame)
        let wasVisible = panel.isVisible
        layout(around: tileFrame, edge: edge, animated: wasVisible)

        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animateIn(generation: generation)
        } else {
            // A show can supersede a fade-out that is still in flight. Restore the
            // visible state immediately; the old completion is rejected by generation.
            panel.alphaValue = 1
            panel.hasShadow = false
            panel.orderFrontRegardless()
        }
    }

    /// Fades the bubble out, then tears it down.
    ///
    /// The teardown order matters: clearing the model first would re-render an empty
    /// bubble for a frame before the window went away. So the window fades, and only once
    /// it is genuinely off screen is the content dropped.
    ///
    /// - Parameter completion: run once the panel is fully hidden. Callers that are about
    ///   to switch Spaces must wait for this — the panel joins all Spaces, so a switch
    ///   started while it is still on screen drags it into the transition.
    func hide(completion: (@Sendable () -> Void)? = nil) {
        let request = visibilityState.beginHide(hasBarrier: completion != nil)
        if request.acceptsBarrier, let completion {
            pendingHideCompletions.append(completion)
        }
        fullSize.hide()
        dockTooltip.restore()
        lastHovered = nil
        lastTileFrame = nil

        guard case let .start(generation) = request.decision else { return }

        guard panel.isVisible else {
            completeHide(generation: generation)
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard Preferences.shared.popupAnimation != .none, !reduceMotion else {
            completeHide(generation: generation)
            return
        }

        // No shadow during the fade, for the same reason as on the way in.
        panel.hasShadow = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // `NSAnimationContext` delivers this on the main thread, but its parameter is
            // an ordinary escaping closure, so the compiler has to assume otherwise.
            // Asserting the isolation is what makes calling main-actor state here legal
            // without deferring it to a later run-loop turn — and it must stay
            // synchronous, because `select` waits on this completion before switching
            // Spaces, and a deferred hop would let the panel be caught in the transition.
            MainActor.assumeIsolated {
                self?.completeHide(generation: generation)
            }
        }
    }

    private func completeHide(generation: UInt) {
        guard visibilityState.finishHide(generation: generation) else { return }
        finishHiding()
        let completions = pendingHideCompletions
        pendingHideCompletions.removeAll(keepingCapacity: true)
        for completion in completions { completion() }
    }

    private func finishHiding() {
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.hasShadow = false
        model.clear()
    }

    /// Drives the full-size preview from whichever tile currently has focus.
    ///
    /// Polled from the hover path rather than pushed from the tile, so keyboard focus
    /// gets the same treatment as the pointer without the view layer needing to know
    /// about the second panel.
    func syncFullSizePreview() {
        guard panel.isVisible else {
            focusSettle?.cancel()
            fullSize.hide()
            return
        }

        let focused = model.focusedWindowID
        guard focused != lastHovered else { return }
        lastHovered = focused

        focusSettle?.cancel()

        guard focused == nil else {
            fullSize.hover(model.focusedWindow, bubbleFrame: panel.frame)
            return
        }

        // Losing focus is deferred briefly. Moving between two adjacent tiles emits a
        // momentary `nil` as the pointer crosses the gap, and acting on it immediately
        // tears the preview down and rebuilds it — a visible blink on every tile the
        // pointer passes over.
        focusSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.model.focusedWindowID == nil else { return }
            self.fullSize.hide()
        }
    }

    /// Updates a single tile's image as it arrives, so the grid fills in progressively.
    func apply(thumbnail: Thumbnail, for id: CGWindowID) {
        guard model.windows.contains(where: { $0.id == id }) else { return }
        model.thumbnails[id] = thumbnail
    }

    /// Takes a preview out of the bubble and reflows it around the gap.
    ///
    /// Re-laying out is not optional: the bubble's size is derived from how many windows
    /// it holds, so dropping one without recomputing leaves a hole where the card was.
    /// The last tile frame and edge are kept for exactly this.
    func removeWindow(_ id: CGWindowID) {
        guard model.windows.contains(where: { $0.id == id }) else { return }
        model.windows.removeAll { $0.id == id }
        model.thumbnails[id] = nil

        guard !model.windows.isEmpty else {
            hide()
            return
        }
        if let tile = lastTileFrame {
            layout(around: tile, edge: model.edge, animated: true)
        }
    }

    /// True when the pointer is inside the bubble, so it should stay open.
    func contains(screenPoint: CGPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint)
    }

    // MARK: - Placement

    private func layout(around tileFrame: CGRect, edge: DockEdge, animated: Bool) {
        let metrics = model.metrics(for: edge)
        let tile = ScreenGeometry.appKitRect(fromAccessibility: tileFrame)
        let gap = CGFloat(Preferences.shared.distanceFromDock)

        var origin = CGPoint.zero
        let screen = ScreenGeometry.screen(containing: CGPoint(x: tile.midX, y: tile.midY))
        let visible = screen?.visibleFrame
        let fullScreen = screen?.frame
        switch edge {
        case .bottom:
            origin.x = tile.midX - metrics.size.width / 2
            let dockTop = visible.flatMap { area in
                guard let fullScreen, area.minY > fullScreen.minY + 1 else { return nil }
                return area.minY
            } ?? tile.maxY
            origin.y = dockTop + gap
        case .left:
            let dockRight = visible.flatMap { area in
                guard let fullScreen, area.minX > fullScreen.minX + 1 else { return nil }
                return area.minX
            } ?? tile.maxX
            origin.x = dockRight + gap
            origin.y = tile.midY - metrics.size.height / 2
        case .right:
            let dockLeft = visible.flatMap { area in
                guard let fullScreen, area.maxX < fullScreen.maxX - 1 else { return nil }
                return area.maxX
            } ?? tile.minX
            origin.x = dockLeft - metrics.size.width - gap
            origin.y = tile.midY - metrics.size.height / 2
        }

        // Keep the bubble on screen; the pointer then slides to stay aimed at the icon
        // rather than the whole bubble hanging off the edge.
        if let visible {
            origin.x = min(max(origin.x, visible.minX + 6),
                           visible.maxX - metrics.size.width - 6)
            origin.y = min(max(origin.y, visible.minY),
                           visible.maxY - metrics.size.height - 6)
        }

        let frame = CGRect(origin: origin, size: metrics.size)

        if animated, frame != panel.frame,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Sliding to a neighbouring Dock icon: glide the whole bubble instead of
            // teleporting it, so the eye keeps track of it. The shadow is dropped for the
            // move because it cannot follow a resizing window smoothly.
            panel.hasShadow = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.settleShadow() }
            }
        } else {
            // `display: false` while the panel is still hidden: forcing a synchronous
            // redraw here just draws a bubble nobody can see yet.
            panel.setFrame(frame, display: panel.isVisible)
        }

        // Position the pointer in the bubble's own coordinates, flipped because SwiftUI
        // draws top-down while the frame above is in AppKit's bottom-up space.
        switch edge {
        case .bottom:
            model.pointerPosition = tile.midX - frame.minX
        case .left, .right:
            model.pointerPosition = frame.maxY - tile.midY
        }

        // A borderless panel keeps a stale rectangular shadow unless it is invalidated
        // after the shape or size changes. Skipped mid-animation: the completion handler
        // does it once the geometry has settled, and recomputing every frame is both
        // wasted work and visibly jittery.
        if !animated { panel.invalidateShadow() }
    }

    private func animateIn(generation: UInt) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard Preferences.shared.popupAnimation != .none, !reduceMotion else {
            panel.alphaValue = 1
            settleShadow()
            return
        }

        // The window shadow of a borderless, transparent panel is derived from the
        // rendered alpha, and AppKit only recomputes it when asked. Leaving it on while
        // the content scales pins a stale, full-size shadow behind a bubble that is still
        // growing — which is most of what read as "not smooth". Drop it for the duration
        // and reinstate it once the geometry has settled.
        panel.hasShadow = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityState.generation == generation else { return }
                self.settleShadow()
            }
        }

        // The content's scale runs alongside the window's fade rather than after it, so
        // the bubble grows *into* view instead of appearing solid and then moving.
        if Preferences.shared.popupAnimation == .snapIn {
            model.snapIn()
        }
    }

    private func settleShadow() {
        // Shadow is baked into the original nine-slice artwork.
        panel.hasShadow = false
    }
}
