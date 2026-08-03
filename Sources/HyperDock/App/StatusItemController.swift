import AppKit

/// The menu-bar presence: HyperDock's only persistent UI.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // AppKit persists `isVisible` on our behalf — it writes `NSStatusItem VisibleCC
        // Item-0` into this app's own defaults — so hiding the icon survived a relaunch
        // even though `Preferences.hideMenuBarIcon` is deliberately not stored. That
        // turned a per-run hide into a permanent one and left no way back: the icon is
        // the only route to Settings, and re-opening the app is only a cure while it is
        // already running. Asserting visibility here restores the intended behaviour,
        // which is that a hidden icon lasts until quit and no longer.
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                   accessibilityDescription: "HyperDock")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on every open so the titles follow a live language change — AppKit menus
    /// do not participate in the SwiftUI environment and would otherwise keep the
    /// language they were first built with.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let previews = item("Window Previews",
                            symbol: Preferences.shared.windowPreviewsEnabled
                                ? "macwindow.on.rectangle" : "macwindow.badge.plus",
                            action: #selector(togglePreviews))
        // A checkmark and an icon cannot share the same slot, so the state is carried by
        // the label instead. Left as a plain item, AppKit reserves the mark column and
        // every icon in the menu shifts right to make room for it.
        previews.title = Localization.string(
            Preferences.shared.windowPreviewsEnabled ? "Window Previews On" : "Window Previews Off")
        menu.addItem(previews)

        if !Permissions.shared.requiredGranted {
            menu.addItem(.separator())
            let warning = item("Permissions needed",
                               symbol: "exclamationmark.triangle.fill",
                               action: #selector(openSettings))
            warning.image?.isTemplate = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        menu.addItem(item("Hide Menu Bar Icon",
                          symbol: "eye.slash",
                          action: #selector(hideMenuBarIcon)))

        menu.addItem(.separator())

        menu.addItem(item("Settings…",
                          symbol: "gearshape",
                          action: #selector(openSettings),
                          key: ","))
        menu.addItem(item("Quit HyperDock",
                          symbol: "power",
                          action: #selector(quit),
                          key: "q"))
    }

    /// Builds a menu item with a consistently sized template icon.
    ///
    /// Every item gets one. Previously only "Settings…" appeared to have an icon — that
    /// was macOS supplying its own for a standard `⌘,` settings item — so the menu read
    /// as one icon and three stragglers, with the labels failing to line up.
    ///
    /// The symbols are pinned to a `.small` scale configuration so glyphs of differing
    /// natural widths (a gear against a power symbol) occupy the same box and the titles
    /// start on a single vertical line.
    private func item(_ key: String.LocalizationValue,
                      symbol: String,
                      action: Selector,
                      key equivalent: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: Localization.string(key),
                                  action: action,
                                  keyEquivalent: equivalent)
        menuItem.target = self

        let configuration = NSImage.SymbolConfiguration(scale: .small)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        menuItem.image = image
        return menuItem
    }

    @objc private func togglePreviews() {
        Preferences.shared.windowPreviewsEnabled.toggle()
    }

    /// Removes the icon from the menu bar for this session.
    ///
    /// HyperDock keeps running — previews and window management are unaffected. The icon
    /// returns the next time the app is opened, which is the whole reason this is a
    /// session-only state: the icon is the only way back into the settings, so making the
    /// hide permanent from inside the app would leave no route to undo it.
    @objc private func hideMenuBarIcon() {
        if !Preferences.shared.hasSeenHideIconNotice {
            let alert = NSAlert()
            alert.messageText = Localization.string("Hide the menu bar icon?")
            alert.informativeText = Localization.string(
                "HyperDock keeps running and window previews still work. To bring the icon back, open HyperDock again from your Applications folder.")
            alert.addButton(withTitle: Localization.string("Hide Icon"))
            alert.addButton(withTitle: Localization.string("Cancel"))
            alert.alertStyle = .informational

            // The alert needs the app forward to be seen at all, since an agent app is
            // never frontmost on its own.
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Preferences.shared.hasSeenHideIconNotice = true
        }

        Preferences.shared.hideMenuBarIcon = true
        statusItem.isVisible = false
    }

    /// Restores the icon. Called when the app is re-opened.
    func showMenuBarIcon() {
        Preferences.shared.hideMenuBarIcon = false
        statusItem.isVisible = true
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(selecting: .general)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
