import SwiftUI

struct AppearancePane: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $preferences.theme) {
                    Text("Automatic").tag(AppearanceTheme.automatic)
                    Text("Classic").tag(AppearanceTheme.classic)
                    Text("Vibrant Light").tag(AppearanceTheme.vibrantLight)
                    Text("Vibrant Dark").tag(AppearanceTheme.vibrantDark)
                    Text("Liquid Glass").tag(AppearanceTheme.liquidGlass)
                }
                Picker("Appear with", selection: $preferences.popupAnimation) {
                    Text("Snap in").tag(PopupAnimation.snapIn)
                    Text("Fade").tag(PopupAnimation.fade)
                    Text("No animation").tag(PopupAnimation.none)
                }
            }

            if preferences.theme == .liquidGlass {
                Section {
                    Text("Liquid Glass follows the transparency and contrast selected in System Settings → Appearance.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Preview size") {
                    // Filled squares of differing size, not two outlined rectangles of
                    // the same weight: `rectangle` at two point sizes renders as a pair
                    // of near-identical empty boxes that say nothing about which end is
                    // which. A small solid square against a large one reads instantly.
                    Slider(value: $preferences.bubbleSize, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "square.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "square.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 180)
                }
                LabeledContent("Previews per row") {
                    NumberField(value: $preferences.previewsPerRow, range: 1...20, digits: 2)
                }
                LabeledContent("Distance from the Dock") {
                    NumberField(value: $preferences.distanceFromDock, range: 0...400, unit: "px")
                }
            } header: { Text("Size and layout") } footer: {
                Text("Previews fill each row up to this limit before starting the next row.")
            }

            Section("Show in each preview") {
                Toggle(isOn: $preferences.showApplicationName) {
                    Text("Application name")
                }
                Toggle(isOn: $preferences.showCloseButton) {
                    Text("Close button")
                }
                Toggle(isOn: $preferences.showSpaceIndicator) {
                    Text("Desktop number and minimized badge")
                }
            }

            Section("Details") {
                Toggle(isOn: $preferences.drawTriangle) {
                    Text("Point an arrow at the Dock icon")
                }
                Toggle(isOn: $preferences.drawHighlightGradient) {
                    Text("Highlight the preview under the pointer")
                }
                Toggle(isOn: $preferences.shadeInvisibleWindows) {
                    Text("Dim minimized windows")
                }
            }
        }
    }
}
