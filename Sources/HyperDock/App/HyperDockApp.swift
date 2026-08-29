import AppKit
import SwiftUI

@main
struct HyperDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app has no ordinary scenes: the status item owns the menu, the settings
        // window is opened on demand, and the preview bubble is an NSPanel. A Settings
        // scene would add an unwanted "Settings…" menu item to a menu bar we never show.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var panelController: PreviewPanelController?
    private var dockWatcher: DockWatcher?
    private var inputMonitor: PreviewInputMonitor?
    private let observers = NotificationObserverBag()
    private var servicesStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bound every Accessibility request for the lifetime of the process before any
        // AX call can be made. Only the system-wide element sets a real process default,
        // and it applies retroactively, so this one call covers everything.
        AXCore.installGlobalTimeout()

        // Agent app: no Dock tile, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        let existingInstallation = Bundle.main.bundleIdentifier.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        } != nil
        Permissions.shared.refresh()
        DockTweaks.migrateLegacyOwnershipIfNeeded(existingInstallation: existingInstallation)

        statusController = StatusItemController()
        DockTweaks.apply()

        let panels = PreviewPanelController()
        panelController = panels
        let monitor = PreviewInputMonitor()
        inputMonitor = monitor
        let watcher = DockWatcher(panelController: panels, inputMonitor: monitor)
        dockWatcher = watcher

        let permissionObserver = NotificationCenter.default.addObserver(
            forName: Permissions.accessibilityDidChange,
            object: Permissions.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileAuthorization() }
        }
        observers.insert(permissionObserver, center: .default)

        Log.permissions.debug("""
            launch: accessibility=\(Permissions.shared.hasAccessibility) \
            screenRecording=\(Permissions.shared.hasScreenRecording) \
            bundle=\(Bundle.main.bundlePath, privacy: .public)
            """)

        // Accessibility alone is enough to run: it is what reads the Dock and controls
        // windows. Screen Recording only adds thumbnails and window titles, so its
        // absence degrades the bubble rather than disabling the feature.
        if Permissions.shared.hasAccessibility {
            startAuthorizedServices()
        }

        Permissions.shared.beginWatching()

        // First launch gets the welcome window instead of the settings pane. An agent app
        // that opens straight into a wall of preferences never explains what it is, and
        // the permissions it needs are the reason it appears to do nothing until granted.
        if !Preferences.shared.hasCompletedOnboarding {
            WelcomeWindowController.shared.show()
        } else if !Permissions.shared.requiredGranted {
            SettingsWindowController.shared.show(selecting: .general)
        }
    }

    private func startAuthorizedServices() {
        guard Permissions.shared.hasAccessibility, !servicesStarted,
              let dockWatcher, let inputMonitor else { return }
        guard inputMonitor.start() else { return }
        dockWatcher.start()
        servicesStarted = true
        Task { await WindowIndex.shared.startTracking() }
    }

    private func reconcileAuthorization() {
        if Permissions.shared.hasAccessibility {
            startAuthorizedServices()
        } else {
            dockWatcher?.stop()
            inputMonitor?.stop()
            servicesStarted = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observers.removeAll()
        dockWatcher?.stop()
        inputMonitor?.stop()
        servicesStarted = false
        Permissions.shared.stopWatching()
        DockTweaks.restore()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from System Settings refreshes both grants immediately; the slow
        // background permission check remains the fallback for an accessory app that
        // does not receive activation.
        Permissions.shared.refresh()
        reconcileAuthorization()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening HyperDock while it is already running brings the menu bar icon back.
    ///
    /// This is the documented way out of a hidden icon, so it has to work from a plain
    /// double-click in the Applications folder. Settings are opened too, since someone
    /// launching an already-running agent app is looking for its interface.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        statusController?.showMenuBarIcon()
        if !hasVisibleWindows {
            SettingsWindowController.shared.show(selecting: .general)
        }
        return true
    }
}
