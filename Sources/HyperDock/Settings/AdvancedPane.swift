import SwiftUI

struct AdvancedPane: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.disabled) {
                    Text("Turn HyperDock off")
                }
                .onChange(of: preferences.disabled) { _, _ in SystemTiling.apply() }
            } header: { EmptyView() } footer: {
                Text("Stops previews and window management without quitting the app.")
            }

            Section {
                LabeledContent("Hide previews after") {
                    NumberField(value: $preferences.previewDeactivationDelay,
                                range: 0...5000, unit: "ms")
                }
                LabeledContent("First full size preview") {
                    NumberField(value: $preferences.fullSizePreviewDelayFirst,
                                range: 0...5000, unit: "ms")
                }
                LabeledContent("Later full size previews") {
                    NumberField(value: $preferences.fullSizePreviewDelaySubsequent,
                                range: 0...5000, unit: "ms")
                }
            } header: { Text("Timing") } footer: {
                Text("The first full size preview waits longer so it does not flash up while the pointer is merely crossing the previews. Once you are scanning, later ones come faster.")
            }

            Section {
                Picker("Quality", selection: $preferences.thumbnailQuality) {
                    Text("Low").tag(ThumbnailQuality.low)
                    Text("Medium").tag(ThumbnailQuality.medium)
                    Text("High").tag(ThumbnailQuality.high)
                }
                Toggle(isOn: $preferences.refreshThumbnailsEnabled) {
                    Text("Keep thumbnails live while open")
                }
                LabeledContent("Refresh every") {
                    DecimalField(value: $preferences.refreshThumbnailsInterval, unit: "s")
                }
                .disabled(!preferences.refreshThumbnailsEnabled)
            } header: { Text("Thumbnails") } footer: {
                Text("Live thumbnails re-capture windows that are on screen, so a playing video keeps moving in its preview.")
            }

            Section {
                Toggle(isOn: $preferences.speedUpDockAutohide) {
                    Text("Reveal a hidden Dock instantly")
                }
                .onChange(of: preferences.speedUpDockAutohide) { _, _ in DockTweaks.apply() }
            } header: { Text("The Dock itself") } footer: {
                Text("This changes your Dock's own setting and restarts it briefly. Turning it off restores the system default.")
            }

            Section {
                Toggle(isOn: $preferences.settingsHotKeyEnabled) {
                    Text("Open Settings from anywhere")
                }
                LabeledContent("Shortcut") {
                    HStack(spacing: 6) {
                        ModifierPicker(combo: $preferences.settingsHotKeyModifiers)
                        Text(verbatim: "H")
                            .font(.body.monospaced())
                            .frame(minWidth: 18)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .disabled(!preferences.settingsHotKeyEnabled)
            } header: { Text("Shortcut") } footer: {
                Text("The menu bar icon can be hidden, and ⌘, only reaches an app that is in front — which HyperDock never is. This shortcut always works.")
            }
        }
    }
}
