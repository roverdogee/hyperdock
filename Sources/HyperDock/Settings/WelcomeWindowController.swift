import AppKit
import SwiftUI

/// The one-time welcome window.
///
/// An agent app arrives invisible: no Dock tile, no window, nothing but a small menu-bar
/// icon that a new user has no reason to look for. Worse, HyperDock does nothing at all
/// until Accessibility is granted, so without this a first launch looks like a launch
/// that failed. This window exists to answer three questions in one screen — what it
/// does, what it needs, and where it lives.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView { [weak self] in
                self?.finish()
            })
            let created = NSWindow(contentViewController: hosting)
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.setContentSize(NSSize(width: 520, height: 600))
            created.center()
            window = created
        }

        // Same reasoning as the settings window: an agent cannot take focus, and this one
        // has buttons that open System Settings, so it has to be genuinely frontmost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Marks onboarding done and closes. Also reached by closing the window, because a
    /// user who dismisses it has still seen it and should not meet it again.
    private func finish() {
        Preferences.shared.hasCompletedOnboarding = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.shared.hasCompletedOnboarding = true
        if let closing = notification.object as? NSWindow, closing === window {
            // This is a one-time surface. Dropping the window also releases its hosting
            // controller, SwiftUI tree and observation graph instead of retaining them
            // for the rest of the process through the singleton.
            window = nil
        }
        Task { @MainActor in
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else {
                return
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct WelcomeView: View {
    let onDone: () -> Void

    @State private var preferences = Preferences.shared
    @State private var permissions = Permissions.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    permissionsSection
                    whereItLivesSection
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .localizedFollowingPreference()
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to HyperDock")
                .font(.title2.weight(.semibold))
            Text("Hover any Dock icon to see every window that app has open — including ones you have minimized or left on another desktop — and click straight through to the one you want.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Two permissions")
                .font(.headline)

            // Ordered by consequence, and labelled with it: Accessibility is the whole
            // feature, Screen Recording only changes how much a preview shows.
            PermissionRow(
                title: "Accessibility",
                detail: "Required. Lets HyperDock read the Dock and control windows.",
                granted: permissions.hasAccessibility,
                action: permissions.openAccessibilitySettings)

            PermissionRow(
                title: "Screen Recording",
                detail: "Optional. Adds thumbnails and window titles; without it previews show app names.",
                granted: permissions.hasScreenRecording,
                action: permissions.openScreenRecordingSettings)

            // Only worth saying while something is still missing; with both granted it
            // is an instruction to do nothing.
            if !permissions.allGranted {
                Text("Grant them in System Settings, then come back — HyperDock notices on its own, with no relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whereItLivesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to find it")
                .font(.headline)
            Label {
                Text("HyperDock has no Dock icon. It lives in the menu bar.")
            } icon: {
                Image(systemName: "menubar.arrow.up.rectangle")
            }
            Label {
                Text("Settings open from that icon, or with \(shortcutDescription) from anywhere.")
            } icon: {
                Image(systemName: "keyboard")
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
    }

    /// Rendered from the live preference, so it stays right if the combination is changed.
    private var shortcutDescription: String {
        let combo = preferences.settingsHotKeyModifiers
        var symbols = ""
        if combo.contains(.control) { symbols += "⌃" }
        if combo.contains(.option) { symbols += "⌥" }
        if combo.contains(.command) { symbols += "⌘" }
        if combo.contains(.shift) { symbols += "⇧" }
        return symbols + "H"
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onDone) {
                Text("Get Started")
                    .frame(minWidth: 90)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !granted {
                Button("Open", action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
