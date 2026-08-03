import SwiftUI

/// The settings window.
///
/// A pinned source list against a grouped-`Form` detail pane — the shape macOS itself
/// now uses for settings. The segmented strip this replaces was a faithful copy of the
/// 2018 original and read as such: a tab bar across the top is simply not what a current
/// macOS settings window looks like.
///
/// Two things do the work of making it feel native, and neither is decoration:
/// the sidebar's own material and selection capsule (never hand-drawn), and letting
/// `Form` own row height, insets and separators. The bilingual label problem solves
/// itself as a side effect — `LabeledContent` measures the label column per language,
/// where a hand-built grid had to be sized for whichever language was wider.
struct SettingsView: View {
    @Bindable var selection: TabSelection
    @State private var preferences = Preferences.shared

    /// Wide enough for the longest label in either language.
    ///
    /// Sized from English, not Chinese: "Window Management" is far longer than 窗口管理,
    /// and a column measured for the Chinese labels truncates it. Scales with the user's
    /// text size so it does not clip at larger sizes either.
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 215

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewColumnWidth(sidebarWidth)
        // The sidebar is the only navigation this window has, so it must never be
        // collapsible — losing it would leave no way to reach the other panes.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 460, idealHeight: 560)
        .localizedFollowingPreference()
    }

    private var sidebar: some View {
        List(selection: bridgedSelection) {
            Section {
                ForEach(SettingsTab.primary) { row($0) }
            }
            Section {
                ForEach(SettingsTab.secondary) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(sidebarWidth)
    }

    private func row(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            TabChip(symbol: tab.symbol, tint: tab.tint)
        }
        .tag(tab)
    }

    /// `NavigationSplitView` writes `nil` into its selection during layout passes, which
    /// would otherwise blank the detail pane. Swallowing the `nil` keeps the last choice.
    private var bridgedSelection: Binding<SettingsTab?> {
        Binding(
            get: { selection.current },
            set: { if let new = $0 { selection.current = new } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selection.current {
            case .general: GeneralPane()
            case .appearance: AppearancePane()
            case .dockItems: DockItemsPane()
            case .windowManagement: WindowManagementPane()
            case .advanced: AdvancedPane()
            case .about: AboutPane()
            }
        }
        // Applied once here rather than in each pane: this is what draws the rounded
        // section cards, the separators between rows and the styled section headers.
        // Without it a `Form` falls back to a plain stack and the headers read as loose
        // text stranded between controls.
        .formStyle(.grouped)
    }
}

/// The tinted rounded-square icon System Settings puts beside each sidebar row.
///
/// Colours come from system semantic colours rather than a bespoke palette, so Increase
/// Contrast keeps its ratios without anything here needing to be re-audited.
struct TabChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Shared controls

/// A numeric field with a stepper and a trailing unit.
///
/// The field is sized by the digits it must hold rather than a fixed point value, so it
/// grows with the user's text size instead of clipping.
struct NumberField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100_000
    var unit: LocalizedStringKey?
    var digits: Int = 4

    @ScaledMetric(relativeTo: .body) private var digitWidth: CGFloat = 11

    var body: some View {
        // Field and stepper stay separate views. Putting the TextField inside
        // `Stepper(value:in:) { }` looks tidier but macOS treats that closure as a plain
        // text label and drops any control in it — the field vanished entirely, leaving
        // just a stepper and a unit.
        //
        // Alignment instead comes from fixing all three widths, so every row in a column
        // has its field, stepper and unit at the same x regardless of how many digits or
        // how long the unit is.
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: CGFloat(digits) * digitWidth + 16)
            Stepper("", value: $value, in: range)
                .labelsHidden()
            if let unit {
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)
            }
        }
    }
}

/// A fractional-seconds field, for the snap delays.
struct DecimalField: View {
    @Binding var value: Double
    var unit: LocalizedStringKey?

    @ScaledMetric(relativeTo: .body) private var digitWidth: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 4 * digitWidth + 16)
            Stepper("", value: $value, in: 0...10, step: 0.1)
                .labelsHidden()
            if let unit {
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)
            }
        }
    }
}

/// The `⌃ ⌥ ⌘ ⇧` modifier row.
///
/// One value, not five independent settings, so it is drawn as a single connected group.
/// Sized with `@ScaledMetric` rather than fixed points: at the largest accessibility text
/// sizes a hard-coded 26×22 cell clips its own glyph.
struct ModifierPicker: View {
    @Binding var combo: ModifierCombo
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 22

    private static let entries: [(ModifierCombo, String, LocalizedStringKey)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.command, "⌘", "Command"),
        (.shift, "⇧", "Shift"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.entries, id: \.1) { modifier, symbol, name in
                let isOn = combo.contains(modifier)
                Button {
                    if isOn { combo.remove(modifier) } else { combo.insert(modifier) }
                } label: {
                    Text(symbol)
                        .font(.body)
                        .frame(minWidth: cell, minHeight: height)
                        .background(
                            isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(Text(name))
                .accessibilityLabel(Text(name))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
