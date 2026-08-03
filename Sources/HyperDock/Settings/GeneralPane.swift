import AppKit
import SwiftUI

struct GeneralPane: View {
    @State private var preferences = Preferences.shared
    @State private var permissions = Permissions.shared

    var body: some View {
        Form {
            if !permissions.allGranted {
                Section { PermissionsNotice() }
            }

            // First, because it is the one setting about the app itself rather than about
            // what it does. Bound to the login item, which is the only part of "runs in
            // the background" that is a choice: HyperDock has no Dock tile and no windows
            // of its own, so while it is running it is always in the background.
            Section {
                Toggle(isOn: $preferences.launchAtLogin) {
                    Text("Run HyperDock in the background")
                }
            } header: { EmptyView() } footer: {
                Text("HyperDock keeps running in the background and starts automatically when you log in.")
            }

            Section {
                Toggle(isOn: $preferences.windowPreviewsEnabled) {
                    Text("Enable window previews")
                }
                LabeledContent("Activation Delay") {
                    NumberField(value: $preferences.activationDelay, range: 0...5000, unit: "ms")
                }
            } header: { EmptyView() } footer: {
                Text("How long the pointer must rest on a Dock icon before previews appear.")
            }

            Section("Include") {
                Toggle(isOn: $preferences.includeWindowsFromAllSpaces) {
                    Text("Windows from all spaces")
                }
                Toggle(isOn: $preferences.includeMinimizedAndHidden) {
                    Text("Minimized and hidden windows")
                }
                Toggle(isOn: $preferences.includePalettes) {
                    Text("Palettes")
                }
            }

            Section("Order") {
                Picker("Sort windows by", selection: $preferences.windowOrder) {
                    Text("Creation time").tag(WindowOrder.creationTime)
                    Text("Title").tag(WindowOrder.title)
                    Text("Stacking order").tag(WindowOrder.stackingOrder)
                }
                Toggle(isOn: $preferences.currentSpaceWindowsFirst) {
                    Text("Show windows from this space first")
                }
            }

            Section("Behaviour") {
                Toggle(isOn: $preferences.showFullSizePreviewOnHover) {
                    Text("Show a full size preview on hover")
                }
                Toggle(isOn: $preferences.hideWhenDockItemClicked) {
                    Text("Hide when a Dock icon is clicked")
                }
                Toggle(isOn: $preferences.hideWhenPreviewClicked) {
                    Text("Hide when a preview is clicked")
                }
                Toggle(isOn: $preferences.skipWhenSingleWindow) {
                    Text("Skip when an app has only one window")
                }
            }

            // Last, and only here: a destructive action belongs at the end of the pane a
            // person is already in, not hidden behind Advanced where someone looking to
            // undo a mess would not think to go.
            Section {
                Button(role: .destructive) {
                    confirmReset()
                } label: {
                    Text("Reset All Settings…")
                }
            } footer: {
                Text("Puts every setting back to how it shipped, including the Dock Items bindings and any per-app overrides.")
            }
        }
    }

    /// Asks first, through `NSAlert` rather than `confirmationDialog`.
    ///
    /// SwiftUI's presentation never appeared from here: attached inside the detail pane of
    /// a `NavigationSplitView` the dialog has no presentation context, and the button
    /// simply did nothing. `NSAlert` is also what the hide-icon confirmation already uses,
    /// so the two destructive prompts in this app now look the same.
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = Localization.string("Reset all settings?")
        alert.informativeText = Localization.string(
            "Every preference returns to its default, per-app Dock bindings are removed, HyperDock stops opening at login, and your Dock's own settings are restored. This cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: Localization.string("Reset"))
        alert.addButton(withTitle: Localization.string("Cancel"))
        // Destructive default would make Return wipe the settings, so the safe button
        // takes the Return key and Reset has to be chosen deliberately.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reset()
    }

    /// Clears the stored settings, then undoes the three effects that live outside them.
    private func reset() {
        // Order matters. The login item and the Dock's keys are read *back* from the
        // system rather than from our defaults, so they have to be put right explicitly —
        // wiping our domain alone would leave HyperDock still launching at login and the
        // Dock still holding a zero auto-hide delay, with nothing in the interface saying
        // so.
        LoginItem.setEnabled(false)
        // These snapshots live in our defaults. Restore them before the persistent
        // domain is cleared, then re-apply the freshly reset HyperDock defaults below.
        DockTweaks.restore()
        SystemTiling.restore()
        Preferences.shared.resetToDefaults()
        DockShortcutStore.shared.resetToDefaults()
        // Reset clears our migration markers too. Re-establish them as a clean install
        // before applying defaults, or the next launch could mistake these new values for
        // an un-migrated legacy override.
        DockTweaks.migrateLegacyOwnershipIfNeeded(existingInstallation: false)
        SystemTiling.migrateLegacyOwnershipIfNeeded(existingInstallation: false)
        DockTweaks.apply()
        SystemTiling.apply()
    }
}

/// Shown while a required permission is missing or the optional thumbnail enhancement
/// is unavailable.
///
/// Given a whole section of its own at the top of the first pane, because without these
/// Accessibility genuinely blocks the app; Screen Recording is presented here as an
/// optional enhancement rather than turning a degraded-but-working launch into an error.
struct PermissionsNotice: View {
    @State private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !permissions.hasAccessibility {
                row(
                    title: "Accessibility access is required",
                    detail: "Lets HyperDock read Dock icons and raise, close and move windows.",
                    action: "Open Accessibility Settings",
                    perform: permissions.openAccessibilitySettings
                )
            }
            if !permissions.hasScreenRecording {
                row(
                    title: "Screen Recording access is optional",
                    detail: "Adds window thumbnails and titles. Without it, previews still work and show application names.",
                    action: "Open Screen Recording Settings",
                    perform: permissions.openScreenRecordingSettings
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: LocalizedStringKey,
                     detail: LocalizedStringKey,
                     action: LocalizedStringKey,
                     perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: perform) { Text(action) }
                    .buttonStyle(.link)
                    .padding(.top, 2)
            }
        }
    }
}
