import AppKit
import Foundation
import SwiftUI

/// What a modified click on a Dock icon does.
///
/// Mission Control is deliberately absent. On macOS 26 no unprivileged process can open
/// it: measured on 26.5.2, `NSWorkspace.openApplication` on Mission Control.app returns
/// neither an application nor an error, `open(1)` and AppleScript do nothing,
/// `CoreDockSendNotification` and a distributed `com.apple.expose.awake` do nothing, and
/// a synthesised ⌃↑ is ignored — the WindowServer handles the Spaces hotkeys itself and
/// discards synthetic events, which the same synthesis opening Spotlight with ⌘Space
/// confirms is specific to those keys rather than a permissions problem.
enum DockAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case quitApp
    case hideApp
    case newWindow
    case showAllWindows
    case minimizeAllWindows
    case relaunchApp

    var id: String { rawValue }

    /// For AppKit surfaces, which resolve against an explicit bundle.
    var titleKey: String.LocalizationValue {
        switch self {
        case .quitApp: "Quit App"
        case .hideApp: "Hide App"
        case .newWindow: "New Window (⌘N)"
        case .showAllWindows: "Show All Windows"
        case .minimizeAllWindows: "Minimize All Windows"
        case .relaunchApp: "Relaunch App"
        }
    }

    /// For SwiftUI, so the string follows the environment locale.
    var title: LocalizedStringKey {
        switch self {
        case .quitApp: "Quit App"
        case .hideApp: "Hide App"
        case .newWindow: "New Window (⌘N)"
        case .showAllWindows: "Show All Windows"
        case .minimizeAllWindows: "Minimize All Windows"
        case .relaunchApp: "Relaunch App"
        }
    }
}

/// Which mouse button triggers a shortcut.
enum DockMouseButton: String, CaseIterable, Identifiable, Codable, Sendable {
    case left, middle, right
    var id: String { rawValue }

    /// For AppKit surfaces, which resolve against an explicit bundle.
    var titleKey: String.LocalizationValue {
        switch self {
        case .left: "Left Click"
        case .middle: "Middle Click"
        case .right: "Right Click"
        }
    }

    /// For SwiftUI, so the string follows the environment locale.
    var title: LocalizedStringKey {
        switch self {
        case .left: "Left Click"
        case .middle: "Middle Click"
        case .right: "Right Click"
        }
    }

    /// Converts only mouse-down events that HyperDock supports into a configured button.
    init?(eventType: CGEventType, buttonNumber: Int64) {
        switch eventType {
        case .leftMouseDown:
            self = .left
        case .rightMouseDown:
            self = .right
        case .otherMouseDown where buttonNumber == 2:
            self = .middle
        default:
            return nil
        }
    }
}

/// A modifier-plus-button combination bound to an action.
struct DockShortcut: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var action: DockAction
    var modifiers: ModifierCombo
    var button: DockMouseButton

    /// Renders as `⌃⌥⌘ + Left Click`, matching the original's Event column.
    var eventDescription: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.command) { symbols += "⌘" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.function) { symbols += "fn" }

        let buttonName = Localization.string(button.titleKey)
        return symbols.isEmpty ? buttonName : "\(symbols) + \(buttonName)"
    }
}

/// The shortcut set for one Dock target — either every icon, or one specific app.
struct DockShortcutScope: Identifiable, Codable, Sendable {
    var id = UUID()
    /// `nil` means "Any Dock Item".
    var bundleIdentifier: String?
    var displayName: String
    var shortcuts: [DockShortcut]

    var isAnyItem: Bool { bundleIdentifier == nil }
}

/// Persists the Dock Items configuration.
@MainActor
@Observable
final class DockShortcutStore {
    static let shared = DockShortcutStore()

    private static let storageKey = "dockShortcutScopes"

    var scopes: [DockShortcutScope] {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([DockShortcutScope].self, from: data),
           !decoded.isEmpty {
            scopes = decoded.map { scope in
                var scope = scope
                scope.shortcuts = scope.shortcuts.map { shortcut in
                    var shortcut = shortcut
                    shortcut.modifiers.formIntersection(.userSelectableSet)
                    return shortcut
                }
                return scope
            }
        } else {
            scopes = [Self.defaultScope]
        }
    }

    /// Defaults mirror the original's shipping bindings.
    private static var defaultScope: DockShortcutScope {
        DockShortcutScope(
            bundleIdentifier: nil,
            displayName: "Any Dock Item",
            shortcuts: [
                DockShortcut(action: .showAllWindows, modifiers: [.option], button: .left),
                DockShortcut(action: .quitApp,
                             modifiers: [.control, .option, .command],
                             button: .left),
                DockShortcut(action: .hideApp, modifiers: [.shift], button: .left),
                DockShortcut(action: .newWindow, modifiers: [], button: .middle),
            ]
        )
    }

    /// Restores the shipping bindings, discarding every per-app override.
    func resetToDefaults() {
        scopes = [Self.defaultScope]
    }

    /// The action bound to a click, preferring an app-specific binding over the
    /// catch-all one so a per-app override always wins.
    func action(forBundle bundleIdentifier: String?,
                modifiers: ModifierCombo,
                button: DockMouseButton) -> DockAction? {
        let specific = scopes.first { $0.bundleIdentifier == bundleIdentifier && $0.bundleIdentifier != nil }
        let any = scopes.first { $0.isAnyItem }

        for scope in [specific, any].compactMap({ $0 }) {
            if let match = scope.shortcuts.first(where: {
                $0.modifiers == modifiers && $0.button == button
            }) {
                return match.action
            }
        }
        return nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scopes) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
