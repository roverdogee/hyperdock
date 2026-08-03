import Foundation
import SwiftUI

/// Resolves which language the interface is drawn in, and provides lookup for the
/// AppKit surfaces that SwiftUI's environment cannot reach.
///
/// Live switching works through `.environment(\.locale, …)`, which really does change
/// `Text` localisation, not just number and date formatting — so changing the language
/// takes effect immediately with no relaunch.
///
/// Two traps this type exists to avoid:
///
///   * `String(localized:locale:)` does **not** translate. Only the `bundle:` argument
///     selects the string table; `locale:` merely picks the plural category. This is the
///     opposite of how `Text` behaves and is the usual cause of a half-translated UI.
///     Every non-SwiftUI lookup here therefore goes through `bundle`.
///
///   * Writing `AppleLanguages` into `UserDefaults` at runtime changes `Locale.current`
///     but does *not* retranslate anything, because CFBundle caches its localisation
///     resolution process-wide. That leaves numbers localised and text not, which is
///     worse than doing nothing. We never touch it.
@MainActor
enum Localization {

    /// The locale to install into the SwiftUI environment.
    static func locale(for language: InterfaceLanguage) -> Locale {
        switch language {
        case .system:
            return Locale.autoupdatingCurrent
        case .simplifiedChinese, .english:
            return Locale(identifier: language.rawValue)
        }
    }

    /// The bundle holding the chosen language's string table.
    ///
    /// Returns the main bundle for `.system` so the normal preferred-language
    /// resolution applies.
    static func bundle(for language: InterfaceLanguage) -> Bundle {
        guard language != .system,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    /// Looks up a string for AppKit surfaces — status-bar menus, alerts, window titles —
    /// which do not participate in the SwiftUI environment and would otherwise stay in
    /// the previous language after a live switch.
    static func string(_ key: String.LocalizationValue,
                       language: InterfaceLanguage = Preferences.shared.language) -> String {
        String(localized: key, bundle: bundle(for: language))
    }
}

extension View {
    /// Applies the user's language choice to a SwiftUI hierarchy.
    ///
    /// Must be reapplied at every SwiftUI *root* — each `NSHostingView` the app creates
    /// for the settings window, the preview bubble and the status menu starts a fresh
    /// environment rather than inheriting the previous one.
    ///
    /// Prefer ``localizedFollowingPreference()``, which also re-renders when the choice
    /// changes. This overload only applies a language that is already known.
    func localized(_ language: InterfaceLanguage) -> some View {
        environment(\.locale, Localization.locale(for: language))
    }

    /// Applies the user's language choice *and* re-renders when it changes.
    ///
    /// Reading `Preferences.revision` is what makes that work. Every setting is a
    /// computed pass-through to `UserDefaults`, so `@Observable` sees no dependency when
    /// a view reads one — the language would change in storage while the interface
    /// carried on in the old one until some unrelated interaction forced a rebuild.
    /// Touching the stored revision counter here registers the dependency that was
    /// missing.
    func localizedFollowingPreference() -> some View {
        modifier(LocalizedModifier())
    }
}

private struct LocalizedModifier: ViewModifier {
    @State private var preferences = Preferences.shared

    func body(content: Content) -> some View {
        // Reading `revision` is deliberate, not redundant: it is the only stored — and
        // therefore observable — property on Preferences.
        let _ = preferences.revision
        return content.environment(\.locale,
                                   Localization.locale(for: preferences.language))
    }
}
