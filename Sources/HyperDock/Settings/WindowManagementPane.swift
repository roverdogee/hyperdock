import SwiftUI

struct WindowManagementPane: View {
    @State private var preferences = Preferences.shared

    /// The move-drag combination, spelled the way the keys are printed.
    private var moveKeys: String {
        let combo = preferences.moveWindowsModifiers
        var symbols = ""
        if combo.contains(.control) { symbols += "⌃" }
        if combo.contains(.option) { symbols += "⌥" }
        if combo.contains(.command) { symbols += "⌘" }
        if combo.contains(.shift) { symbols += "⇧" }
        return symbols.isEmpty ? "—" : symbols
    }

    /// Zero in either field means "decide for me", so the picker writes a starting shape
    /// rather than exposing two magic zeroes.
    private var gridChoice: Binding<Int> {
        Binding(
            get: { preferences.tileGridColumns > 0 || preferences.tileGridRows > 0 ? 1 : 0 },
            set: { choice in
                if choice == 0 {
                    preferences.tileGridColumns = 0
                    preferences.tileGridRows = 0
                } else if preferences.tileGridColumns == 0 && preferences.tileGridRows == 0 {
                    preferences.tileGridColumns = 3
                    preferences.tileGridRows = 2
                }
            })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.snapOnDragToEdge) {
                    Text("Snap when a window is dragged to an edge")
                }
                .onChange(of: preferences.snapOnDragToEdge) { _, _ in SystemTiling.apply() }
                LabeledContent("Delay near the edge") {
                    DecimalField(value: $preferences.snapDelayNearBorder, unit: "s")
                }
                .disabled(!preferences.snapOnDragToEdge)
                LabeledContent("Delay on the edge") {
                    DecimalField(value: $preferences.snapDelayExactBorder, unit: "s")
                }
                .disabled(!preferences.snapOnDragToEdge)
            } header: { Text("Snap to screen edges") } footer: {
                // Says which drag, because it is not the obvious one. macOS does its own
                // tiling for a plain title-bar drag, and two systems snapping the same
                // gesture would fight; this one is reached by holding the move keys.
                Text("Applies while dragging with the move keys held (\(moveKeys)). Pause near an edge to see where the window will land. While this is on, macOS's own drag-to-edge tiling is switched off so the two do not both react to one drag; turning it off puts macOS's back.")
            }

            Section {
                Toggle(isOn: $preferences.keyboardSnapEnabled) {
                    Text("Snap with the keyboard")
                }
                LabeledContent("Hold") {
                    ModifierPicker(combo: $preferences.keyboardSnapModifiers)
                }
                .disabled(!preferences.keyboardSnapEnabled)
            } header: { Text("Keyboard") } footer: {
                Text("With these keys held, the arrows snap the focused window to each half of the screen, Return maximises it, the numeric keypad snaps to corners, and G tiles every window of the front app into a grid.")
            }

            Section {
                Toggle(isOn: $preferences.moveWindowsEnabled) {
                    Text("Move windows by dragging")
                }
                LabeledContent("Hold") {
                    ModifierPicker(combo: $preferences.moveWindowsModifiers)
                }
                .disabled(!preferences.moveWindowsEnabled)

                Toggle(isOn: $preferences.resizeWindowsEnabled) {
                    Text("Resize windows by dragging")
                }
                LabeledContent("Hold") {
                    ModifierPicker(combo: $preferences.resizeWindowsModifiers)
                }
                .disabled(!preferences.resizeWindowsEnabled)
            } header: { Text("Move and resize from anywhere") } footer: {
                Text("Hold the keys and drag anywhere inside a window, not just its title bar. Resizing grows from the corner nearest where the drag began.")
            }

            Section {
                Picker("Grid", selection: gridChoice) {
                    Text("Fit the screen").tag(0)
                    Text("Fixed").tag(1)
                }
                .pickerStyle(.inline)
                if preferences.tileGridColumns > 0 || preferences.tileGridRows > 0 {
                    LabeledContent("Columns") {
                        NumberField(value: $preferences.tileGridColumns, range: 1...12, unit: "")
                    }
                    LabeledContent("Rows") {
                        NumberField(value: $preferences.tileGridRows, range: 1...12, unit: "")
                    }
                }
                LabeledContent("Gap between windows") {
                    NumberField(value: $preferences.tileGridGap, range: 0...80, unit: "pt")
                }
            } header: { Text("Tile in a grid") } footer: {
                Text("Fitting the screen picks the shape from its proportions — two windows side by side, four as 2×2, six as 3×2, eight as 4×2 — so a wide display gets a wide grid.")
            }

            Section {
                Toggle(isOn: $preferences.scrollTitlebarEnabled) {
                    Text("Scroll a title bar to snap the window")
                }
            } header: { Text("Title bar") } footer: {
                Text("Scroll up or down on a title bar to maximise or restore the window; scroll sideways to snap it to the left or right half.")
            }
        }
    }
}
