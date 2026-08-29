import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, advanced, about
    var id: String { rawValue }

    /// For AppKit surfaces, which resolve against an explicit bundle.
    var titleKey: String.LocalizationValue {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// For SwiftUI. This must be a `LocalizedStringKey` rather than a
    /// `String(localized:)` result: only a key is resolved through the environment's
    /// locale, so `String(localized:)` here would leave the tab strip stuck in the
    /// source language while the rest of the pane translates.
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// An SF Symbol per tab. Icons give the sidebar a second, language-independent cue,
    /// which matters more than usual here: the Chinese labels are three or four
    /// characters against much longer English ones, so the list's shape changes entirely
    /// between languages while the icon column stays constant.
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info"
        }
    }

    /// System semantic colours only — nothing bespoke to re-audit under Increase Contrast.
    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .pink
        case .advanced: .purple
        case .about: .gray
        }
    }

    /// The everyday panes.
    static var primary: [SettingsTab] { [.general, .appearance] }

    /// Demoted into a second group: neither is part of daily use, and separating them
    /// says so without needing a header that would outweigh the rows beneath it.
    static var secondary: [SettingsTab] { [.advanced, .about] }
}

/// Hosts the settings window.
///
/// An agent app has no windows of its own by default, so this is created on demand and
/// kept alive between openings to preserve the selected tab.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = TabSelection()

    private override init() { super.init() }

    func show(selecting tab: SettingsTab) {
        selection.current = tab

        if window == nil {
            let root = SettingsView(selection: selection)
            let hosting = NSHostingController(rootView: root)

            let created = NSWindow(contentViewController: hosting)
            // Resizable, and with a full-size content view plus a unified toolbar so the
            // sidebar's material runs up behind the title bar. That continuous strip is
            // most of what distinguishes a current macOS window from a 2018 one — and
            // the window must resize because General and Advanced are taller than any
            // fixed height that also suits About.
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable,
                                 .fullSizeContentView]
            created.titlebarAppearsTransparent = false
            created.toolbarStyle = .unified
            created.toolbar = NSToolbar()
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.setContentSize(NSSize(width: 780, height: 560))
            created.center()
            window = created
        }
        // Retitled on every open so a live language change is reflected; the title is
        // set once at creation and would otherwise keep the language it was born with.
        window?.title = Localization.string("HyperDock")

        // The settings window is the one place the app legitimately comes forward — and
        // becoming a *regular* app is what makes that actually happen. An agent is never
        // frontmost, and macOS 14's cooperative activation ignores `activate` from one, so
        // on its own the window arrived visible and clickable but without keyboard focus:
        // measured, `AXFocused` stayed false and typing went to whichever app was in
        // front, which makes every number field in here unusable. The policy goes back to
        // `.accessory` when the window closes, so the Dock tile lasts only as long as the
        // settings are open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to an agent: no Dock tile, no menu bar, once the window is gone. Deferred
        // because the window is still closing, and dropping the policy underneath it
        // leaves the app frontmost with nothing to show.
        Task { @MainActor in
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else {
                return
            }
            NSApp.setActivationPolicy(.accessory)
        }
        // Keep the controller and its selection; only drop the key window state.
    }
}

/// Shared, observable tab selection so the window controller can deep-link into a tab.
@MainActor
@Observable
final class TabSelection {
    var current: SettingsTab = .general
}
