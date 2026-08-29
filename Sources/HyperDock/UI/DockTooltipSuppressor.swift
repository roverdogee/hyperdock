import CoreGraphics

/// Hides the Dock's own app-name pill while HyperDock's preview is present.
///
/// The tooltip is created after a variable delay, so one immediate lookup is racy. The
/// short bounded poll catches its appearance, and every changed surface is restored when
/// the preview closes. Only small Dock-owned windows adjacent to the active tile qualify.
@MainActor
final class DockTooltipSuppressor {
    private var task: Task<Void, Never>?
    private var hiddenWindows = Set<CGWindowID>()

    func suppress(around tileFrame: CGRect) {
        restore()
        task = Task { [weak self] in
            for _ in 0..<30 {
                guard !Task.isCancelled, let self else { return }
                for id in CGS.dockTooltipWindows(near: tileFrame)
                where self.hiddenWindows.insert(id).inserted {
                    _ = CGS.setWindowAlpha(id, 0)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func restore() {
        task?.cancel()
        task = nil
        for id in hiddenWindows { _ = CGS.setWindowAlpha(id, 1) }
        hiddenWindows.removeAll(keepingCapacity: true)
    }
}
