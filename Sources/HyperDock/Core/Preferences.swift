import AppKit
import Observation

// MARK: - Enumerations

enum AppearanceTheme: String, CaseIterable, Identifiable, Sendable {
    // The first four names and their order come from HyperDock 1.8. Liquid Glass is the
    // native theme added by this implementation for current macOS releases.
    case automatic, classic, vibrantLight, vibrantDark, liquidGlass
    var id: String { rawValue }
}

enum WindowOrder: String, CaseIterable, Identifiable, Sendable {
    case creationTime, recentUsage
    var id: String { rawValue }
}

enum PopupAnimation: String, CaseIterable, Identifiable, Sendable {
    case snapIn, fade, none
    var id: String { rawValue }
}

enum ThumbnailQuality: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }

    /// Multiplier on the captured pixel size.
    ///
    /// Capture cost is dominated by the compositor, not by pixel count, so this is less
    /// about speed than about memory: a bubble of ten previews at 2× Retina holds a
    /// meaningful amount of image data, and Low halves each dimension.
    var scale: CGFloat {
        switch self {
        case .low: 0.5
        case .medium: 0.75
        case .high: 1.0
        }
    }
}

/// Language the interface is presented in, independent of the system setting.
enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
}

/// A set of modifier keys, stored as the raw value of `NSEvent.ModifierFlags`.
struct ModifierCombo: OptionSet, Sendable, Codable, Hashable {
    let rawValue: UInt
    init(rawValue: UInt) { self.rawValue = rawValue }

    static let control = ModifierCombo(rawValue: 1 << 0)
    static let option  = ModifierCombo(rawValue: 1 << 1)
    static let command = ModifierCombo(rawValue: 1 << 2)
    static let shift   = ModifierCombo(rawValue: 1 << 3)
    static let function = ModifierCombo(rawValue: 1 << 4)

    /// Every modifier the event normaliser can identify without ambiguity.
    ///
    /// `maskSecondaryFn` is also attached to built-in arrow keys automatically, so it
    /// cannot distinguish a physical Fn press from an ordinary arrow-key shortcut.
    static let userSelectable: [ModifierCombo] = [.control, .option, .command, .shift]
    static let userSelectableSet: ModifierCombo = [.control, .option, .command, .shift]

    init(eventFlags flags: CGEventFlags) {
        var value: ModifierCombo = []
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskCommand) { value.insert(.command) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        self = value
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.function) { flags.insert(.function) }
        return flags
    }
}

// MARK: - Store

/// Every user-facing setting, persisted to `UserDefaults`.
///
/// Defaults capture the maintainer's tested 0.5 configuration: a compact Liquid Glass
/// preview with restrained animation and low-frequency live refresh. Existing users keep
/// their persisted choices; these values apply to fresh installs and Reset to Defaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let store = UserDefaults.standard
    private init() {
        migrateThumbnailSizeMappingIfNeeded()
    }

    /// Preserves the visible size chosen in builds whose 0…1 slider meant 150…350 pt.
    /// A setting that was never written instead receives the new old-HyperDock default.
    private func migrateThumbnailSizeMappingIfNeeded() {
        let versionKey = "thumbnailSizeMappingVersion"
        guard store.integer(forKey: versionKey) < 2 else { return }
        if let oldSlider = store.object(forKey: "bubbleSize") as? Double {
            let oldWidth = 150 + min(max(oldSlider, 0), 1) * 200
            store.set(BubbleModel.sliderValue(forThumbnailWidth: oldWidth),
                      forKey: "bubbleSize")
        }
        store.set(2, forKey: versionKey)
    }

    /// Bumped whenever any setting is written.
    ///
    /// Every property here is a computed pass-through to `UserDefaults`, which
    /// `@Observable` cannot see: it tracks reads and writes of *stored* properties, so a
    /// getter that reaches straight into defaults registers no dependency and a setter
    /// posts no change. Controls bound with `$preferences.x` still work, because the
    /// binding drives the control directly — which is why this went unnoticed.
    ///
    /// It only surfaced with `language`, the one setting that has to redraw views other
    /// than its own control: switching it left the interface in the old language until
    /// something else forced a rebuild. This stored property is the observable signal
    /// those views depend on.
    private(set) var revision = 0

    /// Writes through to `UserDefaults` and tells observers something changed.
    private func write(_ value: Any?, _ key: String) {
        store.set(value, forKey: key)
        revision &+= 1
    }

    /// Reads a stored value, registering an observation dependency on the way.
    ///
    /// Touching `revision` inside every getter is what makes a control bound to one of
    /// these properties redraw when the value changes. Without it a `Picker` writes the
    /// new selection through to defaults but keeps displaying the old one, because
    /// nothing told SwiftUI its source had moved.
    private func observed<T>(_ read: () -> T) -> T {
        _ = revision
        return read()
    }

    // MARK: General

    var windowPreviewsEnabled: Bool {
        get { observed { bool("windowPreviewsEnabled", default: true) } }
        set { write(newValue, "windowPreviewsEnabled") }
    }

    /// Milliseconds the pointer must rest on a Dock tile before the bubble appears.
    var activationDelay: Int {
        get { observed { int("activationDelay", default: 70) } }
        set { write(newValue, "activationDelay") }
    }

    var includeWindowsFromAllSpaces: Bool {
        get { observed { bool("includeWindowsFromAllSpaces", default: true) } }
        set { write(newValue, "includeWindowsFromAllSpaces") }
    }

    var includeMinimizedAndHidden: Bool {
        get { observed { bool("includeMinimizedAndHidden", default: true) } }
        set { write(newValue, "includeMinimizedAndHidden") }
    }

    var includePalettes: Bool {
        get { observed { bool("includePalettes", default: true) } }
        set { write(newValue, "includePalettes") }
    }

    var windowOrder: WindowOrder {
        get {
            observed {
                switch store.string(forKey: "windowOrder") {
                case "stackingOrder": return .recentUsage
                case "title": return .creationTime
                default: return enumValue("windowOrder", default: .creationTime)
                }
            }
        }
        set { write(newValue.rawValue, "windowOrder") }
    }

    var currentSpaceWindowsFirst: Bool {
        get { observed { bool("currentSpaceWindowsFirst", default: true) } }
        set { write(newValue, "currentSpaceWindowsFirst") }
    }

    /// Enlarges the hovered thumbnail into a full-size preview after a delay.
    var showFullSizePreviewOnHover: Bool {
        get { observed { bool("showFullSizePreviewOnHover", default: false) } }
        set { write(newValue, "showFullSizePreviewOnHover") }
    }

    /// Milliseconds before the first full-size preview appears in a bubble.
    var fullSizePreviewDelayFirst: Int {
        get { observed { int("fullSizePreviewDelayFirst", default: 500) } }
        set { write(newValue, "fullSizePreviewDelayFirst") }
    }

    /// Milliseconds before subsequent full-size previews appear, once the user is
    /// already scanning across a bubble.
    var fullSizePreviewDelaySubsequent: Int {
        get { observed { int("fullSizePreviewDelaySubsequent", default: 200) } }
        set { write(newValue, "fullSizePreviewDelaySubsequent") }
    }

    var hideWhenDockItemClicked: Bool {
        get { observed { bool("hideWhenDockItemClicked", default: true) } }
        set { write(newValue, "hideWhenDockItemClicked") }
    }

    var hideWhenPreviewClicked: Bool {
        get { observed { bool("hideWhenPreviewClicked", default: true) } }
        set { write(newValue, "hideWhenPreviewClicked") }
    }

    var skipWhenSingleWindow: Bool {
        get { observed { bool("skipWhenSingleWindow", default: false) } }
        set { write(newValue, "skipWhenSingleWindow") }
    }

    // MARK: Appearance

    var theme: AppearanceTheme {
        get {
            observed {
                // Migrate the compatibility build's earlier light/dark values to the
                // corresponding original HyperDock choices.
                switch store.string(forKey: "theme") {
                case "light": return .vibrantLight
                case "dark": return .vibrantDark
                default: return enumValue("theme", default: .liquidGlass)
                }
            }
        }
        set { write(newValue.rawValue, "theme") }
    }

    var showApplicationName: Bool {
        get { observed { bool("showApplicationName", default: true) } }
        set { write(newValue, "showApplicationName") }
    }

    var showCloseButton: Bool {
        get { observed { bool("showCloseButton", default: true) } }
        set { write(newValue, "showCloseButton") }
    }

    /// A short delay prevents accidental closure without making the control feel late.
    var closeButtonDelay: Int {
        get { observed { int("closeButtonDelay", default: 100) } }
        set { write(newValue, "closeButtonDelay") }
    }

    var showSpaceIndicator: Bool {
        get { observed { bool("showSpaceIndicator", default: true) } }
        set { write(newValue, "showSpaceIndicator") }
    }

    /// Gap in points between the Dock and the bottom of the bubble.
    var distanceFromDock: Int {
        get { observed { int("distanceFromDock", default: 0) } }
        set { write(newValue, "distanceFromDock") }
    }

    /// Relative bubble scale, 0…1, mapped to a thumbnail width range.
    var bubbleSize: Double {
        get { observed { double("bubbleSize", default: 0.182) } }
        set { write(newValue, "bubbleSize") }
    }

    var previewsPerRow: Int {
        get { observed { int("previewsPerRow", default: 5) } }
        set { write(max(1, newValue), "previewsPerRow") }
    }

    var popupAnimation: PopupAnimation {
        get { observed { enumValue("popupAnimation", default: .fade) } }
        set { write(newValue.rawValue, "popupAnimation") }
    }

    var drawTriangle: Bool {
        get { observed { bool("drawTriangle", default: true) } }
        set { write(newValue, "drawTriangle") }
    }

    var drawHighlightGradient: Bool {
        get { observed { bool("drawHighlightGradient", default: true) } }
        set { write(newValue, "drawHighlightGradient") }
    }

    var shadeInvisibleWindows: Bool {
        get { observed { bool("shadeInvisibleWindows", default: true) } }
        set { write(newValue, "shadeInvisibleWindows") }
    }

    // MARK: Advanced

    var disabled: Bool {
        get { observed { bool("disabled", default: false) } }
        set { write(newValue, "disabled") }
    }

    /// Pops the Dock up immediately when it is hidden or the user is on a full-screen
    /// Space, instead of waiting for the system's own reveal delay.
    var speedUpDockAutohide: Bool {
        get { observed { bool("speedUpDockAutohide", default: false) } }
        set { write(newValue, "speedUpDockAutohide") }
    }

    /// Milliseconds the bubble lingers after the pointer leaves, so the user can move
    /// diagonally into it without it vanishing.
    var previewDeactivationDelay: Int {
        get { observed { int("previewDeactivationDelay", default: 0) } }
        set { write(newValue, "previewDeactivationDelay") }
    }

    var thumbnailQuality: ThumbnailQuality {
        get { observed { enumValue("thumbnailQuality", default: .medium) } }
        set { write(newValue.rawValue, "thumbnailQuality") }
    }

    var refreshThumbnailsEnabled: Bool {
        get { observed { bool("refreshThumbnailsEnabled", default: true) } }
        set { write(newValue, "refreshThumbnailsEnabled") }
    }

    var refreshThumbnailsInterval: Double {
        get { observed { double("refreshThumbnailsInterval", default: 5) } }
        set { write(newValue, "refreshThumbnailsInterval") }
    }

    /// Hides the menu-bar icon.
    ///
    /// Deliberately *not* persisted as "hidden forever": it resets on every launch, so
    /// re-opening HyperDock always brings the icon back. A menu-bar app whose only
    /// visible affordance can be permanently switched off from inside itself is a trap —
    /// the user has no way left to reach the settings that would undo it.
    var hideMenuBarIcon: Bool = false

    /// Whether the user has been told how to get the icon back. Shown once.
    var hasSeenHideIconNotice: Bool {
        get { observed { bool("hasSeenHideIconNotice", default: false) } }
        set { write(newValue, "hasSeenHideIconNotice") }
    }

    /// Whether HyperDock is registered to start at login.
    ///
    /// Reads and writes the login item itself rather than a stored copy of the answer.
    /// A stored copy drifts: registration can fail, and the user can remove the item in
    /// System Settings, either of which leaves the switch showing "on" for something
    /// that will not happen. `revision` still participates so the control redraws.
    var launchAtLogin: Bool {
        get { observed { LoginItem.isEnabled } }
        set {
            LoginItem.setEnabled(newValue)
            revision &+= 1
        }
    }

    /// Whether ⌃⌥⌘H (or whatever modifiers are set) opens Settings from anywhere.
    ///
    /// The menu-bar icon is otherwise the only route in, and it can be hidden. `⌘,` does
    /// not help: it only reaches an application that is frontmost, which an agent never is.
    var settingsHotKeyEnabled: Bool {
        get { observed { bool("settingsHotKeyEnabled", default: false) } }
        set { write(newValue, "settingsHotKeyEnabled") }
    }

    var settingsHotKeyModifiers: ModifierCombo {
        get { observed { modifiers("settingsHotKeyModifiers", default: [.control, .option, .command]) } }
        set { write(newValue.rawValue, "settingsHotKeyModifiers") }
    }

    /// Cleared only by a fresh install, so the welcome window is shown exactly once.
    var hasCompletedOnboarding: Bool {
        get { observed { bool("hasCompletedOnboarding", default: false) } }
        set { write(newValue, "hasCompletedOnboarding") }
    }

    // MARK: Language

    var language: InterfaceLanguage {
        get { observed { enumValue("language", default: .system) } }
        set { write(newValue.rawValue, "language") }
    }

    // MARK: - Reset

    /// Returns every setting to its shipping value.
    ///
    /// Removes the whole persistent domain rather than writing each key back: that also
    /// clears state this type does not own but AppKit writes into the same domain — the
    /// status item's remembered visibility, window frame autosaves — which is what a
    /// person means by "reset", and leaving it behind is how a reset ends up not fixing
    /// whatever prompted it.
    ///
    /// Side effects outside the domain are the caller's to finish: the login item and the
    /// Dock key written into the Dock's own domain both live elsewhere.
    func resetToDefaults() {
        if let domain = Bundle.main.bundleIdentifier {
            store.removePersistentDomain(forName: domain)
        }
        revision &+= 1
    }

    // MARK: - Backing helpers

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    private func int(_ key: String, default fallback: Int) -> Int {
        store.object(forKey: key) as? Int ?? fallback
    }

    private func double(_ key: String, default fallback: Double) -> Double {
        store.object(forKey: key) as? Double ?? fallback
    }

    private func enumValue<T: RawRepresentable>(_ key: String, default fallback: T) -> T
    where T.RawValue == String {
        guard let raw = store.string(forKey: key), let value = T(rawValue: raw) else {
            return fallback
        }
        return value
    }

    private func modifiers(_ key: String, default fallback: ModifierCombo) -> ModifierCombo {
        guard let raw = store.object(forKey: key) as? UInt else { return fallback }
        // Strip modifiers an older build exposed but could never observe. Otherwise a
        // saved Fn bit makes the entire exact-match shortcut permanently unreachable.
        return ModifierCombo(rawValue: raw).intersection(.userSelectableSet)
    }
}
