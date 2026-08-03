import SwiftUI

struct AboutPane: View {
    @State private var preferences = Preferences.shared
    @State private var permissions = Permissions.shared

    /// The version as a person would say it.
    ///
    /// Build number omitted: it means something to whoever compiled the app and nothing
    /// to whoever is reading this pane.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HyperDock")
                            .font(.title3.weight(.semibold))
                        Text("Version \(version)")
                            .foregroundStyle(.secondary)
                        // Says what the app does for the reader, not how it was built.
                        // "Rebuilt natively for Apple Silicon" described the project's
                        // history, which is of no use to someone deciding what this
                        // window is for.
                        Text("Hover any Dock icon to see every window that app has open — including ones you have minimized or left on another desktop — and click straight through to the one you want.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("Interface language", selection: $preferences.language) {
                    // "System" is translated because it describes a behaviour, but each
                    // language is named in itself — a reader looking for their own
                    // language finds it whatever the interface currently shows.
                    Text("Match System").tag(InterfaceLanguage.system)
                    Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                }
            } header: { Text("Language") } footer: {
                Text("Takes effect immediately — no restart needed.")
            }

            Section {
                LabeledContent("Accessibility") {
                    PermissionBadge(granted: permissions.hasAccessibility,
                                    open: permissions.openAccessibilitySettings)
                }
                LabeledContent("Screen Recording") {
                    PermissionBadge(granted: permissions.hasScreenRecording,
                                    open: permissions.openScreenRecordingSettings)
                }
            } header: { Text("Permissions") } footer: {
                Text("Accessibility lets HyperDock read the Dock and control windows. Screen Recording provides thumbnails and window titles.")
            }
        }
    }
}

struct PermissionBadge: View {
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(granted ? "Granted" : "Not granted")
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
            }
            if !granted {
                Button("Open Settings", action: open)
                    .buttonStyle(.link)
            }
        }
    }
}
