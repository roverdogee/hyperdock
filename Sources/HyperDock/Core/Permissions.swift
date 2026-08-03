import AppKit
import CoreGraphics
import Observation

/// Tracks the required Accessibility grant and the optional Screen Recording enhancement.
///
/// Both are granted in System Settings and neither can be requested silently, so the
/// app has to keep watching for them to appear rather than checking once at launch.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()
    static let accessibilityDidChange = Notification.Name(
        "HyperDock.Permissions.accessibilityDidChange")

    /// Required to enumerate Dock tiles and to raise, close or move windows.
    private(set) var hasAccessibility = false

    /// Required for window thumbnails, and also for window *titles* — on modern macOS
    /// `kCGWindowName` comes back empty without it.
    private(set) var hasScreenRecording = false

    /// Accessibility is the only permission required for the product to operate.
    var requiredGranted: Bool { hasAccessibility }
    var allGranted: Bool { hasAccessibility && hasScreenRecording }

    private var pollTimer: Timer?

    private init() {
        refresh()
    }

    func refresh() {
        let previousAccessibility = hasAccessibility
        hasAccessibility = AXCore.isTrusted
        // Preflight checks the grant *without* showing a prompt, unlike
        // CGRequestScreenCaptureAccess.
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        if previousAccessibility != hasAccessibility {
            NotificationCenter.default.post(name: Self.accessibilityDidChange, object: self)
        }
    }

    /// Polls quickly while the required permission is missing, then slowly for revocation.
    ///
    /// There is no notification for a TCC grant, and the user leaves the app to toggle
    /// a switch in System Settings, so polling is the only way to notice.
    /// Accessibility is the launch gate, so missing access is noticed promptly. Once it
    /// is granted, a low-frequency check remains because an accessory app is not
    /// guaranteed to become active after the user revokes access in System Settings. The
    /// optional Screen Recording state never selects the polling rate.
    func beginWatching() {
        guard pollTimer == nil else { return }
        let interval = Self.pollingInterval(hasAccessibility: hasAccessibility)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if Self.pollingInterval(hasAccessibility: self.hasAccessibility) != interval {
                    self.stopWatching()
                    self.beginWatching()
                }
            }
        }
        pollTimer = timer
    }

    static func pollingInterval(hasAccessibility: Bool) -> TimeInterval {
        hasAccessibility ? 15 : 1
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Requests

    /// Shows the system Accessibility prompt.
    func requestAccessibility() {
        AXCore.requestTrust()
    }

    /// Triggers the Screen Recording prompt.
    ///
    /// Apple documents that the grant only takes effect after a relaunch, so the UI
    /// tells the user that rather than leaving them wondering why nothing changed.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
